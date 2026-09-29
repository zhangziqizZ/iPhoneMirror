// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙预览渲染器实现：EGL + GLES3，NV12 → RGB。
//
// 数据来源与上游 Linux 版一致：预览侧不直接持有会话，而是通过
// OhosCaptureBridge 拉最新待渲染帧（next_render_frame 的所有权归预览侧独享）。
// 渲染在独立线程上跑，避免把 USB/解码热路径拖进 GPU 提交。

#include "OhosPreviewRenderer.h"

#include "OhosCaptureBridge.h"

#include <Logging.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <format>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>

#if defined(__has_include)
#  if __has_include(<native_window/external_window.h>)
#    include <native_window/external_window.h>
#    define IM_HAVE_OHOS_NATIVE_WINDOW 1
#  endif
#  if __has_include(<EGL/egl.h>) && __has_include(<GLES3/gl3.h>)
#    include <EGL/egl.h>
#    include <GLES3/gl3.h>
#    define IM_HAVE_OHOS_GLES 1
#  endif
#endif

#ifndef IM_HAVE_OHOS_NATIVE_WINDOW
#  define IM_HAVE_OHOS_NATIVE_WINDOW 0
#endif
#ifndef IM_HAVE_OHOS_GLES
#  define IM_HAVE_OHOS_GLES 0
#endif

namespace iPhoneMirror::media {
namespace {

// 预览挂载自愈的限流参数。
//
// 为什么需要自愈：XComponent 的 onLoad 只触发一次。如果那一刻 surface 还没就绪
// （或者 EGL 初始化被瞬时占用），attach 就会失败，而此后没有任何事件会再叫我们
// 重试 —— 表现就是「解码器一直在出帧、预览区永远全黑、没有任何报错」。
// 这里在推帧侧做限流重试：最多 kPreviewReattachMax 次、每次间隔 ≥ 1 秒，
// 既能把"时机不对"救回来，又不会退化成每秒几十次 EGL 初始化。
constexpr std::uint64_t kPreviewReattachMax = 12;
constexpr std::int64_t kPreviewReattachIntervalMs = 1000;

// 渲染线程等不到新帧时去采集桥取帧的节奏（USB 路径沿用旧的 4ms 轮询）。
constexpr std::int64_t kPreviewPollIntervalMs = 4;

// attach() 等渲染线程建好 EGL 的上限。超时不代表失败到底 —— 渲染线程可能只是
// 卡在一个阻塞的 eglSwapBuffers 上；这里必须设上限，否则 JS 线程会被卡住。
constexpr std::int64_t kAttachWaitSeconds = 5;

std::int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

#if IM_HAVE_OHOS_GLES
// ── 顶点着色器 ──────────────────────────────────────────────────────────────
//
//   content_scale：等比缩放后画面在 NDC 里的半宽/半高（保持宽高比，留黑边而
//                  不拉伸 —— 预览区是任意比例的，直接铺满会把画面拉变形）。
//   rotation     ：顺时针 90° 的整数倍旋转矩阵（列主序传入）。
//   先缩放再旋转：旋转后的矩形半宽高正好互换，与 C++ 侧算圆角用的尺寸一致。
constexpr const char* VertexShader = R"(#version 300 es
layout(location = 0) in vec2 position;
uniform vec2 content_scale;
uniform mat2 rotation;
out vec2 uv;
void main() {
    // 纹理坐标上下翻转：GL 的裁剪空间 Y 向上，视频帧 Y 向下。
    uv = vec2((position.x + 1.0) * 0.5, 1.0 - (position.y + 1.0) * 0.5);
    gl_Position = vec4(rotation * (position * content_scale), 0.0, 1.0);
})";

// ── 片元着色器 ──────────────────────────────────────────────────────────────
//
// 分三步：
//   1) YUV→RGB（BT.709 limited range，系数与 VideoFormats.h 的 CPU 路径同一套）
//   2) 图像调节：反伽马 → 亮度 → 对比度 → 饱和度
//      （顺序取自上游 im_set_image_adjustments 的语义：gamma 是"提亮/压暗"，
//        contrast 以中灰为轴，saturation 以 Rec.709 亮度为轴）
//   3) 超椭圆圆角裁剪：圆角外的片元 alpha 置 0（半径 0 时整段跳过）
constexpr const char* FragmentShader = R"(#version 300 es
precision mediump float;
in vec2 uv;
uniform sampler2D y_texture;
uniform sampler2D uv_texture;
uniform float brightness;
uniform float contrast;
uniform float saturation;
uniform float inv_gamma;
uniform vec2 center;
uniform vec2 half_size;
uniform float corner_radius;
uniform float corner_exponent;
out vec4 colour;

void main() {
    // 采集流是 BT.709 limited range；这里与 details 的 CPU 色彩数学保持同一套
    // 系数（上游 VideoFormats.h 的 YuvConversionParameters 默认值）。
    float y = (texture(y_texture, uv).r - 0.0625) * 1.16438;
    float cb = texture(uv_texture, uv).r - 0.5;
    float cr = texture(uv_texture, uv).g - 0.5;
    vec3 rgb = vec3(y + 1.5748 * cr,
                    y - 0.187324 * cb - 0.468124 * cr,
                    y + 1.8556 * cb);

    rgb = clamp(rgb, 0.0, 1.0);
    rgb = pow(rgb, vec3(inv_gamma));
    rgb = rgb + brightness;
    rgb = (rgb - 0.5) * contrast + 0.5;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(vec3(luma), rgb, saturation);

    float alpha = 1.0;
    if (corner_radius > 0.5) {
        vec2 q = max(abs(gl_FragCoord.xy - center) - (half_size - vec2(corner_radius)), 0.0);
        float n = max(corner_exponent, 1.5);
        float d = pow(pow(q.x / corner_radius, n) + pow(q.y / corner_radius, n), 1.0 / n);
        // 1 像素的过渡带，免得圆角边缘出现硬锯齿。
        alpha = 1.0 - clamp(d - 1.0, 0.0, 1.0);
        if (alpha <= 0.0) discard;
    }

    colour = vec4(clamp(rgb, 0.0, 1.0), alpha);
})";

GLuint compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_FALSE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

    // 顺时针旋转矩阵（列主序 mat2）：gl_Position = rotation * (position * content_scale)。
    // 验证：(1,0) 经 Cw90 → (0,-1)，正好是顺时针 90°。
    constexpr float RotationIdentity[4] = {1.0F, 0.0F, 0.0F, 1.0F};
    constexpr float RotationCw90[4]    = {0.0F, -1.0F, 1.0F, 0.0F};
    constexpr float RotationCw180[4]   = {-1.0F, 0.0F, 0.0F, -1.0F};
    constexpr float RotationCw270[4]   = {0.0F, 1.0F, -1.0F, 0.0F};
#endif

} // namespace

// ── 为什么 EGL/GL 调用必须全部挤在同一个线程上 ──────────────────────────────
//
// EGLContext 是**按线程 current** 的：eglMakeCurrent 只对调用它的那个线程生效。
// 此前 attach() 由 ArkTS 的 onLoad 经 NAPI 调进来（跑在 JS 线程上）建上下文并
// eglMakeCurrent，而 draw() 跑在 AirPlay 的 RTP 线程（USB 路径上是预览泵线程）上，
// 于是 draw() 里那句 eglMakeCurrent 必然失败 —— 而它的返回值被丢掉了：
//   ① 没有 current 上下文时，所有 gl* 调用退化成空操作，glGetError() 恒返回 0；
//   ② eglSwapBuffers 每帧都返回 EGL_FALSE。
// 真机实测的指纹：已解码 163 帧 / present 163 / "画成功" 163 / swap 失败 163 /
// glErr 0 —— 画面全黑却一处报错都没有。其中"画成功 163"是假成功：旧代码在 swap
// 失败时也照样给 draw_ok 加一。现在只有 swap 真成功才算画成。
//
// 结构因此改成：渲染器持有一个**专属渲染线程**，建 EGL、draw 上屏、销毁 EGL 全在
// 它上面做；其它线程（JS 线程、RTP 线程、NAPI 调用）只投递请求、不碰 GL。
// 顺带修掉了"present 在 RTP 热路径上同步做 GPU 提交"的问题。
struct OhosPreviewRenderer::Impl {
    // ── 渲染线程与请求队列 ───────────────────────────────────────────────
    std::mutex mutex;
    std::condition_variable cv;
    std::thread render_thread;
    bool thread_running{false};
    bool quit_requested{false};

    // 一次"换 surface"请求（id == 0 表示释放）。attach() 置位后等回执。
    bool surface_request_pending{false};
    std::uint64_t surface_request_id{0};
    bool surface_result_ready{false};
    bool surface_result_ok{false};

    // 待绘制的帧，只保留最新一帧：渲染跟不上时丢旧帧，不吃延迟。
    std::optional<DecodedFrame> pending_frame;

    // 对外可见的状态（渲染线程写，其它线程读）。
    std::atomic<bool> gl_ready{false};              // = attached()：EGL 上下文可用
    // 最近一次 attach() **请求**的 surfaceId（成败都记）。自愈重挂用得到它：
    // 挂载失败时没有"已挂上的 id"可退，只能拿请求过的 id 再试一次。
    std::atomic<std::uint64_t> last_requested_surface_id{0};

    // 预览侧图像/圆角/旋转设置的唯一存储地（draw 在 mutex 下读，set_* 写；用
    // atomic 让只读访问器也能免锁回读）。
    std::atomic<float> brightness_{0.0F};
    std::atomic<float> contrast_{1.0F};
    std::atomic<float> saturation_{1.0F};
    std::atomic<float> gamma_{1.0F};
    std::atomic<float> normalized_radius_{0.0F};
    std::atomic<float> curve_exponent_{2.0F};
    std::atomic<std::int32_t> quarter_turns_{0};

    // ── 渲染链诊断（见 .h 的 PreviewRendererDiag 说明）──────────────────
    // 刻意不放在 destroy_gl() 里清零：attach 失败、surface 销毁这些事件正是
    // 需要留下痕迹的东西，清了就白采了。
    std::atomic<std::uint64_t> diag_attach_calls{0};
    std::atomic<std::uint64_t> diag_attach_failures{0};
    std::atomic<std::uint64_t> diag_detach_calls{0};
    std::atomic<std::uint64_t> diag_present_calls{0};
    std::atomic<std::uint64_t> diag_pump_frames{0};
    std::atomic<std::uint64_t> diag_draw_calls{0};
    std::atomic<std::uint64_t> diag_draw_ok{0};
    std::atomic<std::uint64_t> diag_drop_no_display{0};
    std::atomic<std::uint64_t> diag_drop_not_nv12{0};
    std::atomic<std::uint64_t> diag_drop_empty{0};
    std::atomic<std::uint64_t> diag_drop_zero_dim{0};
    std::atomic<std::uint64_t> diag_drop_too_small{0};
    std::atomic<std::uint64_t> diag_swap_failures{0};
    std::atomic<std::uint64_t> diag_make_current_failures{0};
    std::atomic<std::int32_t>  diag_last_gl_error{0};
    std::atomic<std::int32_t>  diag_last_egl_error{0};
    std::atomic<std::uint32_t> diag_surface_w{0};
    std::atomic<std::uint32_t> diag_surface_h{0};
    std::atomic<std::uint32_t> diag_frame_w{0};
    std::atomic<std::uint32_t> diag_frame_h{0};
    std::atomic<std::uint32_t> diag_frame_bytes{0};
    std::atomic<std::uint32_t> diag_frame_format{0};
    std::atomic<std::uint32_t> diag_frame_stride{0};
    // 自愈重挂的计数与节流时刻（见 kPreviewReattachMax 的说明）。
    std::atomic<std::uint64_t> diag_reattach_attempts{0};
    std::atomic<std::int64_t>  last_reattach_ms{0};

#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
    // ── 以下这些句柄**只有渲染线程能碰**（create_gl / destroy_gl / draw）──
    OHNativeWindow* window{};
    EGLDisplay display{EGL_NO_DISPLAY};
    EGLSurface surface{EGL_NO_SURFACE};
    EGLContext context{EGL_NO_CONTEXT};
    EGLConfig config{};
    GLuint program{};
    GLuint y_texture{};
    GLuint uv_texture{};
    GLuint vertex_buffer{};
    GLuint vao{};
    std::uint32_t texture_width{};
    std::uint32_t texture_height{};
#endif

    void destroy_gl() noexcept {
#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
        if (display != EGL_NO_DISPLAY) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (y_texture != 0) glDeleteTextures(1, &y_texture);
            if (uv_texture != 0) glDeleteTextures(1, &uv_texture);
            if (program != 0) glDeleteProgram(program);
            if (vao != 0) glDeleteVertexArrays(1, &vao);
            if (vertex_buffer != 0) glDeleteBuffers(1, &vertex_buffer);
            if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
            if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
            eglTerminate(display);
        }
        if (window != nullptr) {
            OH_NativeWindow_DestroyNativeWindow(window);
        }
        window = nullptr;
        display = EGL_NO_DISPLAY;
        surface = EGL_NO_SURFACE;
        context = EGL_NO_CONTEXT;
        program = 0;
        y_texture = 0;
        uv_texture = 0;
        vertex_buffer = 0;
        vao = 0;
        texture_width = 0;
        texture_height = 0;
#endif
    }

#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
    // 只在渲染线程上调用。
    bool create_gl(std::uint64_t surface_id) {
        const auto result = OH_NativeWindow_CreateNativeWindowFromSurfaceId(
            surface_id, &window);
        if (result != 0 || window == nullptr) return false;

        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY) return false;
        if (eglInitialize(display, nullptr, nullptr) != EGL_TRUE) return false;

        const EGLint attributes[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 8, EGL_NONE};
        EGLint config_count = 0;
        if (eglChooseConfig(display, attributes, &config, 1, &config_count) != EGL_TRUE ||
            config_count == 0) {
            return false;
        }
        surface = eglCreateWindowSurface(display, config,
            reinterpret_cast<EGLNativeWindowType>(window), nullptr);
        if (surface == EGL_NO_SURFACE) return false;

        const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
        if (context == EGL_NO_CONTEXT) return false;
        if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) return false;

        const GLuint vertex = compile(GL_VERTEX_SHADER, VertexShader);
        const GLuint fragment = compile(GL_FRAGMENT_SHADER, FragmentShader);
        if (vertex == 0 || fragment == 0) return false;
        program = glCreateProgram();
        glAttachShader(program, vertex);
        glAttachShader(program, fragment);
        glLinkProgram(program);
        glDeleteShader(vertex);
        glDeleteShader(fragment);
        GLint linked = 0;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (linked == GL_FALSE) return false;

        // 两个三角形覆盖整屏；纹理坐标在顶点着色器里由位置推出。
        static const GLfloat quad[] = {
            -1.0F, -1.0F, 1.0F, -1.0F, -1.0F, 1.0F,
            -1.0F, 1.0F, 1.0F, -1.0F, 1.0F, 1.0F};
        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glGenBuffers(1, &vertex_buffer);
        glBindBuffer(GL_ARRAY_BUFFER, vertex_buffer);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(GLfloat), nullptr);

        glGenTextures(1, &y_texture);
        glBindTexture(GL_TEXTURE_2D, y_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glGenTextures(1, &uv_texture);
        glBindTexture(GL_TEXTURE_2D, uv_texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        return true;
    }

    void ensure_textures(const DecodedFrame& frame) {
        if (texture_width == frame.width && texture_height == frame.height) return;
        texture_width = frame.width;
        texture_height = frame.height;
        glBindTexture(GL_TEXTURE_2D, y_texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, static_cast<GLsizei>(frame.width),
            static_cast<GLsizei>(frame.height), 0, GL_RED, GL_UNSIGNED_BYTE, nullptr);
        glBindTexture(GL_TEXTURE_2D, uv_texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RG8, static_cast<GLsizei>(frame.width / 2),
            static_cast<GLsizei>(frame.height / 2), 0, GL_RG, GL_UNSIGNED_BYTE, nullptr);
    }

    // 当前 EGLSurface 的像素尺寸。每帧查一次：窗口大小会变（用户拖窗口、
    // 切全屏、Surface 重建），而 EGL 没有给我们一个尺寸变化回调。
    // eglQuerySurface 是一次用户态查询，比维护一套回调可靠得多。
    bool query_surface_size(int& width, int& height) {
        EGLint w = 0;
        EGLint h = 0;
        if (eglQuerySurface(display, surface, EGL_WIDTH, &w) != EGL_TRUE) return false;
        if (eglQuerySurface(display, surface, EGL_HEIGHT, &h) != EGL_TRUE) return false;
        if (w <= 0 || h <= 0) return false;
        width = static_cast<int>(w);
        height = static_cast<int>(h);
        return true;
    }

    bool draw(const DecodedFrame& frame) {
        diag_draw_calls.fetch_add(1, std::memory_order_relaxed);
        // 无论成败都记现场：黑屏排查时，"最后一帧长什么样"比"失败了多少次"更关键。
        diag_frame_w.store(frame.width, std::memory_order_relaxed);
        diag_frame_h.store(frame.height, std::memory_order_relaxed);
        diag_frame_bytes.store(static_cast<std::uint32_t>(frame.nv12.size()),
            std::memory_order_relaxed);
        diag_frame_format.store(static_cast<std::uint32_t>(frame.pixel_format),
            std::memory_order_relaxed);
        diag_frame_stride.store(static_cast<std::uint32_t>(frame.stride),
            std::memory_order_relaxed);

        if (frame.pixel_format != PixelFormat::Nv12) {
            diag_drop_not_nv12.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (frame.nv12.empty()) {
            diag_drop_empty.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (frame.width == 0 || frame.height == 0) {
            diag_drop_zero_dim.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        const std::size_t luma_bytes =
            static_cast<std::size_t>(frame.width) * frame.height;
        if (frame.nv12.size() < luma_bytes + luma_bytes / 2) {
            diag_drop_too_small.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        // ── EGL 句柄有效性（渲染线程独占写，这里读自己写的值）───────────────
        if (display == EGL_NO_DISPLAY || surface == EGL_NO_SURFACE ||
            context == EGL_NO_CONTEXT) {
            diag_drop_no_display.fetch_add(1, std::memory_order_relaxed);
            return false;
        }

        // ── eglMakeCurrent 的返回值必须看 ──────────────────────────────────
        // 失败 = 本线程拿不到 EGL 上下文，后面所有 gl* 会静默变成空操作
        // （glGetError 恒 0）、eglSwapBuffers 必然失败。这正是"解码正常、
        // 画了 N 帧、画面全黑、零报错"的成因，必须留下指纹。
        if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
            diag_make_current_failures.fetch_add(1, std::memory_order_relaxed);
            diag_last_egl_error.store(static_cast<std::int32_t>(eglGetError()),
                std::memory_order_relaxed);
            return false;
        }
        ensure_textures(frame);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, y_texture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(frame.width),
            static_cast<GLsizei>(frame.height), GL_RED, GL_UNSIGNED_BYTE,
            frame.nv12.data());
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, uv_texture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, static_cast<GLsizei>(frame.width / 2),
            static_cast<GLsizei>(frame.height / 2), GL_RG, GL_UNSIGNED_BYTE,
            frame.nv12.data() + luma_bytes);

        // ── viewport 必须是 surface 的尺寸，不是帧的尺寸 ───────────────────
        // 用帧尺寸会让 glViewport 与真实 surface 不一致：窗口比帧大时只画了
        // 左上角一块，比帧小时又画到了界外。这是移植说明第 10 节里点名的
        // 待修项，这里改掉。
        int surface_width = 0;
        int surface_height = 0;
        if (!query_surface_size(surface_width, surface_height)) {
            // 查不到就退回纹理尺寸，至少不会把整个预览画没。
            // 但诊断里留 0：surface 尺寸查不到本身就说明 surface 已经不可用了。
            surface_width = static_cast<int>(frame.width);
            surface_height = static_cast<int>(frame.height);
        } else {
            diag_surface_w.store(static_cast<std::uint32_t>(surface_width),
                std::memory_order_relaxed);
            diag_surface_h.store(static_cast<std::uint32_t>(surface_height),
                std::memory_order_relaxed);
        }
        glViewport(0, 0, surface_width, surface_height);
        // alpha 置 0：圆角/黑边之外的像素交给下层的 ArkUI 预览底色。
        glClearColor(0.0F, 0.0F, 0.0F, 0.0F);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        // ── 等比适配：保持宽高比，留黑边，绝不拉伸 ─────────────────────────
        const double frame_width = static_cast<double>(frame.width);
        const double frame_height = static_cast<double>(frame.height);
        const double scale = std::min(
            static_cast<double>(surface_width) / frame_width,
            static_cast<double>(surface_height) / frame_height);
        const double drawn_width = frame_width * scale;
        const double drawn_height = frame_height * scale;
        const float content_scale[2] = {
            static_cast<float>(drawn_width / surface_width),
            static_cast<float>(drawn_height / surface_height)};

        // 顺时针 90° 旋转矩阵（列主序，见匿名命名空间的 RotationXxx）。
        const int turns = ((quarter_turns_.load() % 4) + 4) % 4;
        const float* rotation_matrix = turns == 0 ? RotationIdentity
            : (turns == 1 ? RotationCw90 : (turns == 2 ? RotationCw180 : RotationCw270));

        // 旋转后画面在 surface 里的实际像素半宽/半高（画圆角要用）。
        const bool swapped = (turns == 1 || turns == 3);
        const float half_size[2] = {
            static_cast<float>((swapped ? drawn_height : drawn_width) * 0.5),
            static_cast<float>((swapped ? drawn_width : drawn_height) * 0.5)};
        const float center[2] = {static_cast<float>(surface_width) * 0.5F,
            static_cast<float>(surface_height) * 0.5F};

        // 圆角半径：normalized_radius 相对短边（CoreApi.h 的约定）。
        const float short_edge = static_cast<float>(std::min(surface_width, surface_height));
        const float radius = normalized_radius_ * short_edge;

        const float gamma = std::max(gamma_.load(), 0.01F);

        glUseProgram(program);
        glUniform1i(glGetUniformLocation(program, "y_texture"), 0);
        glUniform1i(glGetUniformLocation(program, "uv_texture"), 1);
        glUniform2fv(glGetUniformLocation(program, "content_scale"), 1, content_scale);
        glUniformMatrix2fv(glGetUniformLocation(program, "rotation"), 1, GL_FALSE,
            rotation_matrix);
        glUniform1f(glGetUniformLocation(program, "brightness"), brightness_);
        glUniform1f(glGetUniformLocation(program, "contrast"), contrast_);
        glUniform1f(glGetUniformLocation(program, "saturation"), saturation_);
        glUniform1f(glGetUniformLocation(program, "inv_gamma"), 1.0F / gamma);
        glUniform2fv(glGetUniformLocation(program, "center"), 1, center);
        glUniform2fv(glGetUniformLocation(program, "half_size"), 1, half_size);
        glUniform1f(glGetUniformLocation(program, "corner_radius"), radius);
        glUniform1f(glGetUniformLocation(program, "corner_exponent"), curve_exponent_);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        // glGetError 是粘性的：把这一帧积下的错读到干净，同时记下最后一个非零值。
        // （必须在 swap 之前读 —— swap 之后的 glGetError 已经是下一帧的现场了。）
        GLenum gl_error = GL_NO_ERROR;
        for (GLenum e = glGetError(); e != GL_NO_ERROR; e = glGetError()) gl_error = e;
        diag_last_gl_error.store(static_cast<std::int32_t>(gl_error),
            std::memory_order_relaxed);
        const EGLBoolean swap_ok = eglSwapBuffers(display, surface);
        if (swap_ok != EGL_TRUE) {
            diag_swap_failures.fetch_add(1, std::memory_order_relaxed);
            diag_last_egl_error.store(static_cast<std::int32_t>(eglGetError()),
                std::memory_order_relaxed);
            // 不再往下走：swap 失败这一帧就没上屏，绝不能计成"画成功"。
            return false;
        }
        diag_draw_ok.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
#endif

    // ── 渲染线程 ─────────────────────────────────────────────────────────
    // 退出：让渲染线程自己把 EGL 释放干净后再 join。
    void shutdown() noexcept {
        {
            std::scoped_lock lock(mutex);
            if (!thread_running) {
                destroy_gl();       // 线程从未启动，句柄本来就是空的
                return;
            }
            quit_requested = true;
        }
        cv.notify_all();
        if (render_thread.joinable()) render_thread.join();
        std::scoped_lock lock(mutex);
        thread_running = false;
        gl_ready.store(false, std::memory_order_release);
    }

#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
    // 首次 attach 时启动，此后常驻（detach 只释放 surface，不销毁线程：
    // 反复建/拆线程会让 EGL 资源与 surface 生命周期互相纠缠）。
    bool ensure_render_thread() {
        std::scoped_lock lock(mutex);
        if (thread_running) return true;
        quit_requested = false;
        surface_request_pending = false;
        pending_frame.reset();
        try {
            render_thread = std::thread([this] { render_main(); });
        } catch (...) {
            return false;
        }
        thread_running = true;
        return true;
    }

    void render_main() {
        std::unique_lock lock(mutex);
        for (;;) {
            if (quit_requested) break;

            if (surface_request_pending) {
                surface_request_pending = false;
                const std::uint64_t id = surface_request_id;
                lock.unlock();
                destroy_gl();
                const bool ok = (id != 0) && create_gl(id);
                if (!ok) destroy_gl();
                lock.lock();
                // 换 surface 期间攒下的帧（含重挂失败时留下的旧帧）一律作废：
                // 它们的尺寸/内容对新的 surface 可能已经没有意义了。
                pending_frame.reset();
                gl_ready.store(ok, std::memory_order_release);
                surface_result_ok = ok;
                surface_result_ready = true;
                cv.notify_all();
                continue;
            }

            if (pending_frame.has_value()) {
                DecodedFrame frame = std::move(*pending_frame);
                pending_frame.reset();
                lock.unlock();
                draw(frame);
                lock.lock();
                continue;
            }

            if (gl_ready.load(std::memory_order_acquire)) {
                // USB 路径：等不到推来的帧就自己去采集桥取一帧（沿用旧 4ms 节奏）。
                cv.wait_for(lock, std::chrono::milliseconds(kPreviewPollIntervalMs));
                if (!surface_request_pending && !pending_frame.has_value() &&
                    !quit_requested) {
                    lock.unlock();
                    auto frame = ohos_bridge::latest_render_frame();
                    if (frame) draw(*frame);
                    lock.lock();
                    if (frame) diag_pump_frames.fetch_add(1, std::memory_order_relaxed);
                }
            } else {
                // 没挂上 surface 时不必轮询，否则空转 250 次/秒。
                cv.wait(lock);
            }
        }
        lock.unlock();
        destroy_gl();           // 必须在本线程释放 EGL
    }
#endif
};

OhosPreviewRenderer::OhosPreviewRenderer() : impl_(std::make_unique<Impl>()) {}

OhosPreviewRenderer::~OhosPreviewRenderer() { impl_->shutdown(); }

OhosPreviewRenderer& OhosPreviewRenderer::instance() {
    // 故意 new 出来永不 delete：本类的 EGL 上下文活在一个专属线程上，如果让静态
    // 局部变量在进程退出时析构，就得在那个时刻 join 渲染线程 —— 而它可能正卡在
    // 一次阻塞的 eglSwapBuffers 里，退出流程会因此挂住。句柄泄漏一份给进程寿命，
    // 换来"退出绝不阻塞"。（非单例用法仍走正常析构：~OhosPreviewRenderer 会 join。）
    static OhosPreviewRenderer* renderer = new OhosPreviewRenderer();
    return *renderer;
}

bool OhosPreviewRenderer::attach(std::uint64_t surface_id) {
    impl_->diag_attach_calls.fetch_add(1, std::memory_order_relaxed);
#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
    impl_->last_requested_surface_id.store(surface_id, std::memory_order_relaxed);
    if (surface_id == 0) {
        std::scoped_lock lock(impl_->mutex);
        impl_->diag_attach_failures.fetch_add(1, std::memory_order_relaxed);
        last_error_ = "surfaceId 为 0，无法建立 EGL 上下文";
        return false;
    }
    if (!impl_->ensure_render_thread()) {
        std::scoped_lock lock(impl_->mutex);
        impl_->diag_attach_failures.fetch_add(1, std::memory_order_relaxed);
        last_error_ = "无法启动预览渲染线程";
        return false;
    }
    {
        std::unique_lock lock(impl_->mutex);
        impl_->surface_request_id = surface_id;
        impl_->surface_request_pending = true;
        impl_->surface_result_ready = false;
        impl_->surface_result_ok = false;
        impl_->cv.notify_all();
        // 建 EGL 的活必须由渲染线程干（EGL 上下文按线程 current），这里只等回执。
        const bool answered = impl_->cv.wait_for(lock,
            std::chrono::seconds(kAttachWaitSeconds),
            [this] { return impl_->surface_result_ready; });
        if (!answered) {
            impl_->diag_attach_failures.fetch_add(1, std::memory_order_relaxed);
            last_error_ = std::format(
                "等待渲染线程挂载 surfaceId={} 超过 {} 秒（渲染线程可能被阻塞的 eglSwapBuffers 卡住）",
                surface_id, kAttachWaitSeconds);
            return false;
        }
        if (!impl_->surface_result_ok) {
            impl_->diag_attach_failures.fetch_add(1, std::memory_order_relaxed);
            last_error_ = std::format(
                "无法在 surfaceId={} 上建立 EGL 上下文（OH_NativeWindow_CreateNativeWindowFromSurfaceId、eglCreateWindowSurface 或 eglMakeCurrent 失败）",
                surface_id);
            return false;
        }
        last_error_.clear();
    }
    return true;
#else
    (void)surface_id;
    std::scoped_lock lock(impl_->mutex);
    impl_->diag_attach_failures.fetch_add(1, std::memory_order_relaxed);
    last_error_ = "该 SDK 未提供 NativeWindow/EGL/GLES，预览不可用";
    return false;
#endif
}

void OhosPreviewRenderer::detach() noexcept {
    impl_->diag_detach_calls.fetch_add(1, std::memory_order_relaxed);
    // 只投递"释放 surface"请求，不等回执：调用方（含进程退出路径）不该被一次
    // 阻塞的 eglSwapBuffers 拖住。真正的 destroy_gl 由渲染线程执行。
    std::scoped_lock lock(impl_->mutex);
    if (!impl_->thread_running) return;
    impl_->surface_request_id = 0;
    impl_->surface_request_pending = true;
    impl_->cv.notify_all();
}

bool OhosPreviewRenderer::attached() const noexcept {
    return impl_->gl_ready.load(std::memory_order_acquire);
}

void OhosPreviewRenderer::present(DecodedFrame frame) {
    uint64_t retry_surface = 0;
    {
        std::scoped_lock lock(impl_->mutex);
        impl_->diag_present_calls.fetch_add(1, std::memory_order_relaxed);
#if IM_HAVE_OHOS_NATIVE_WINDOW && IM_HAVE_OHOS_GLES
        if (impl_->gl_ready.load(std::memory_order_acquire)) {
            // 只投递。同一时刻最多留一帧：渲染跟不上时丢旧帧，不堆延迟。
            impl_->pending_frame.emplace(std::move(frame));
            impl_->cv.notify_all();
            return;
        }
        // 没挂上 surface 就丢掉（调用方已把这帧计入"已解码"，所以这里必须留痕，
        // 否则「解码 190 帧、画面全黑」看不出原因）。
        impl_->diag_drop_no_display.fetch_add(1, std::memory_order_relaxed);
        retry_surface = impl_->last_requested_surface_id.load(std::memory_order_relaxed);
#else
        (void)frame;
#endif
    }
    // ── 未挂载时限流自愈 ─────────────────────────────────────────────────
    // 必须放在锁外：attach() 要拿同一把 mutex。还要限流，否则每帧都试一次
    // EGL 初始化，60fps 下会把设备拖垮。
    if (retry_surface != 0) {
        const std::int64_t now = now_ms();
        const std::int64_t last = impl_->last_reattach_ms.load(std::memory_order_relaxed);
        if (impl_->diag_reattach_attempts.load(std::memory_order_relaxed) < kPreviewReattachMax &&
            (last == 0 || now - last >= kPreviewReattachIntervalMs)) {
            impl_->last_reattach_ms.store(now, std::memory_order_relaxed);
            impl_->diag_reattach_attempts.fetch_add(1, std::memory_order_relaxed);
            attach(retry_surface);
        }
    }
}

void OhosPreviewRenderer::set_image_adjustments(float brightness, float contrast,
    float saturation, float gamma) {
    impl_->brightness_.store(brightness);
    impl_->contrast_.store(contrast);
    impl_->saturation_.store(saturation);
    impl_->gamma_.store(gamma);
}

void OhosPreviewRenderer::set_corner_profile(float normalized_radius,
    float curve_exponent) {
    impl_->normalized_radius_.store(normalized_radius);
    impl_->curve_exponent_.store(curve_exponent);
}

void OhosPreviewRenderer::set_rotation(std::int32_t quarter_turns) {
    impl_->quarter_turns_.store(quarter_turns);
}

float OhosPreviewRenderer::brightness() const { return impl_->brightness_.load(); }
float OhosPreviewRenderer::contrast() const { return impl_->contrast_.load(); }
float OhosPreviewRenderer::saturation() const { return impl_->saturation_.load(); }
float OhosPreviewRenderer::gamma() const { return impl_->gamma_.load(); }
float OhosPreviewRenderer::normalized_radius() const {
    return impl_->normalized_radius_.load();
}
float OhosPreviewRenderer::curve_exponent() const {
    return impl_->curve_exponent_.load();
}
std::int32_t OhosPreviewRenderer::quarter_turns() const {
    return impl_->quarter_turns_.load();
}

void OhosPreviewRenderer::fill_diag(PreviewRendererDiag *out) const {
    if (out == nullptr) return;
    // impl_ 是 unique_ptr：const 方法里 get() 仍给出可写指针，这里只用来读
    // 受 mutex 保护的 last_error_（其余全是 atomic，无需加锁）。
    Impl *p = impl_.get();
    const auto r = std::memory_order_relaxed;
    std::string last_error;
    {
        std::scoped_lock lock(p->mutex);
        last_error = last_error_;
    }
    out->attach_calls     = p->diag_attach_calls.load(r);
    out->attach_failures  = p->diag_attach_failures.load(r);
    out->detach_calls     = p->diag_detach_calls.load(r);
    out->attached         = p->gl_ready.load(r) ? 1u : 0u;
    out->present_calls    = p->diag_present_calls.load(r);
    out->pump_frames      = p->diag_pump_frames.load(r);
    out->draw_calls       = p->diag_draw_calls.load(r);
    out->draw_ok          = p->diag_draw_ok.load(r);
    out->drop_no_display  = p->diag_drop_no_display.load(r);
    out->drop_not_nv12    = p->diag_drop_not_nv12.load(r);
    out->drop_empty       = p->diag_drop_empty.load(r);
    out->drop_zero_dim    = p->diag_drop_zero_dim.load(r);
    out->drop_too_small   = p->diag_drop_too_small.load(r);
    out->swap_failures    = p->diag_swap_failures.load(r);
    out->make_current_failures = p->diag_make_current_failures.load(r);
    out->reattach_attempts= p->diag_reattach_attempts.load(r);
    out->last_gl_error    = p->diag_last_gl_error.load(r);
    out->last_egl_error   = p->diag_last_egl_error.load(r);
    out->surface_width    = p->diag_surface_w.load(r);
    out->surface_height   = p->diag_surface_h.load(r);
    out->last_frame_w     = p->diag_frame_w.load(r);
    out->last_frame_h     = p->diag_frame_h.load(r);
    out->last_frame_bytes = p->diag_frame_bytes.load(r);
    out->last_frame_format= p->diag_frame_format.load(r);
    out->last_frame_stride= p->diag_frame_stride.load(r);
    // 失败原因：留最新一次 attach 的错误串（成功时 attach 会 clear 掉）。
    std::strncpy(out->last_error, last_error.c_str(), sizeof(out->last_error) - 1);
    out->last_error[sizeof(out->last_error) - 1] = '\0';
}

extern "C" void im_preview_renderer_diag(PreviewRendererDiag *out) {
    OhosPreviewRenderer::instance().fill_diag(out);
}

} // namespace iPhoneMirror::media
