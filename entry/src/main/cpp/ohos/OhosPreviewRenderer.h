// SPDX-License-Identifier: GPL-3.0-only
//
// 鸿蒙预览渲染器：把解码出的 NV12/P010 帧画到 XComponent 的 surface 上。
//
// 对照上游：
//  * Windows 是 D3D11PreviewRenderer（D3D11 + DirectComposition 接到子 HWND）；
//  * Linux 是 LinuxPlaceboRenderer（libplacebo/Vulkan 渲染到可导出镜像，
//    再由 Avalonia 导入，见 docs/LINUX_PORT.md 的 D1 决策）；
//  * 鸿蒙是 EGL + GLES：ArkTS 侧的 XComponentController 给出 surfaceId，
//    原生侧用 OH_NativeWindow_CreateNativeWindowFromSurfaceId 拿到 OHNativeWindow，
//    在其上建 EGLSurface，用两片纹理承载 Y 与 UV，着色器里做 YUV→RGB。
//
// 与 ABI 的衔接：上游 C ABI 的预览入口是 im_attach_preview_window(void* hwnd)，
// 语义是"给我一个可供渲染的原生窗口句柄"。鸿蒙上这个句柄就是 surfaceId ——
// NAPI 桥把 getXComponentSurfaceId() 得到的字符串转成整数再当句柄传下来，
// 因此 ABI 声明一个字都不用改。

#pragma once

#include "Media/VideoFormats.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>

namespace iPhoneMirror::media {

// 完整定义在文件末尾。这里前置声明是为了让下面的类能声明 fill_diag()，而不必
// 让类定义依赖诊断结构体的布局。
struct PreviewRendererDiag;

class OhosPreviewRenderer {
public:
    OhosPreviewRenderer();
    ~OhosPreviewRenderer();
    OhosPreviewRenderer(const OhosPreviewRenderer&) = delete;
    OhosPreviewRenderer& operator=(const OhosPreviewRenderer&) = delete;

    // surface_id 即 XComponentController.getXComponentSurfaceId() 的数值形式。
    // 内部把"建 EGL"交给渲染线程执行（EGL 上下文按线程 current，见 .cpp），本调用
    // 只等回执，所以是同步返回的。返回 false 表示 EGL 初始化失败 / 渲染线程起不来 /
    // 等回执超时，原因串在 last_error()。
    [[nodiscard]] bool attach(std::uint64_t surface_id);
    void detach() noexcept;
    [[nodiscard]] bool attached() const noexcept;

    // 交一帧给渲染线程。**本函数只投递，不在这里画**：GPU 上传与 draw 全部由
    // 渲染器自己的线程执行（原因见 .cpp 顶部「EGL 线程独占」）。已经有还没画的
    // 帧时，新帧替换旧帧（丢旧帧保低延迟），因此调用方可以放心地按 60fps 投递。
    // 按值传参是刻意的：调用方 move 进来可以省掉每帧 1.7MB 的拷贝。
    // 内部只做 GPU 上传与一次 draw，外加下面这几个纯预览侧的后处理；导出的
    // BGRA 帧（截图/录制）走的是 CPU 路径，不受这些设置影响。
    void present(DecodedFrame frame);

    // ── 预览侧图像调节（对应 CoreApi.h 的 im_set_image_adjustments）──────────
    //   brightness ∈ [-1, 1]   加在归一化亮度上的偏移
    //   contrast   ∈ [0, 2]    以 0.5 为轴的线性缩放
    //   saturation ∈ [0, 2]    以 Rec.709 亮度为轴的饱和度缩放
    //   gamma      ∈ [0.5, 2]  先做 1/gamma 的反伽马（即"提亮"是增大 gamma）
    // 超出区间的值由调用方（CoreApi）负责拒绝；这里只做"存下来"。
    void set_image_adjustments(float brightness, float contrast, float saturation,
        float gamma);

    // ── 圆角裁剪（对应 im_set_preview_corner_profile）────────────────────────
    //   normalized_radius 相对短边，0 = 关闭
    //   curve_exponent    ∈ [1.5, 8]，超椭圆指数（2 = 正圆角）
    void set_corner_profile(float normalized_radius, float curve_exponent);

    // ── 旋转（对应 im_session_set_window_rotation）──────────────────────────
    //   quarter_turns 为 90° 的整数倍；只接受 0/1/2/3（内部会取模归一化）。
    void set_rotation(std::int32_t quarter_turns);

    // ── 当前生效的设置（供状态回读与自测）──────────────────────────────────
    // 设置值唯一的存储地在 Impl 里（由 mutex 保护），这几个只读访问器只是回读。
    [[nodiscard]] float brightness() const;
    [[nodiscard]] float contrast() const;
    [[nodiscard]] float saturation() const;
    [[nodiscard]] float gamma() const;
    [[nodiscard]] float normalized_radius() const;
    [[nodiscard]] float curve_exponent() const;
    [[nodiscard]] std::int32_t quarter_turns() const;

    [[nodiscard]] const std::string& last_error() const noexcept { return last_error_; }

    // 填充渲染链诊断快照（供下面的 im_preview_renderer_diag 使用）。
    void fill_diag(PreviewRendererDiag *out) const;

    // 进程内唯一的预览实例：C ABI 的预览入口是无句柄的（im_attach_preview_window
    // 只收一个 hwnd），上游也是全局一份。
    [[nodiscard]] static OhosPreviewRenderer& instance();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::string last_error_;
};

// ── 渲染链诊断快照 ─────────────────────────────────────────────────────────
//
// 为什么需要它：present() → draw() 这条路上，失败**全是静默的** —— draw 有五条
// 裸 `return false`（格式不对 / 空数据 / 零尺寸 / buffer 不足 / 无 surface），
// present() 在没挂上 surface 时只是把帧丢掉。于是"解码器已解出 N 帧、画面全黑"
// 这种症状完全无从判断卡在哪一环。（1.0.7 正是靠这里的计数才认出"每帧 swap 全败"，
// 进而定位到 EGL 上下文被跨线程使用 —— 见 .cpp 顶部的说明。）
//
// 这里把每个失败分支分别计数，并用 im_preview_renderer_diag() 回读给 UI。
// 判读口径：
//   * draw_ok == 0 且 drop_no_display > 0 → 根本没 attach（surface 未挂上）；
//   * draw_ok == 0 且 drop_not_nv12 / drop_empty > 0 → 解码器交出的帧不可用；
//   * make_current_failures > 0 → 本线程没拿到 EGL 上下文（GL 调用会静默变成
//     空操作、glGetError 恒 0、swap 必然失败）；这是"跨线程用 EGL"的指纹；
//   * swap_failures == draw_calls > 0 → 每帧都 swap 失败，看 last_egl_error；
//   * draw_ok > 0 但屏幕仍黑 → 看 surface_width/height 是否为 0（surface 已失效）。
struct PreviewRendererDiag {
    // attach / detach
    std::uint64_t attach_calls{0};
    std::uint64_t attach_failures{0};
    std::uint64_t detach_calls{0};
    std::uint32_t attached{0};          // 1 = 渲染线程已建好 EGL 上下文

    // 帧入口
    std::uint64_t present_calls{0};     // AirPlay 直推路径调用 present() 的次数
    std::uint64_t pump_frames{0};       // 预览泵（USB 路径）取到并绘制的帧数

    // draw 内部分支
    std::uint64_t draw_calls{0};        // draw() 进入次数（两条路径合计）
    std::uint64_t draw_ok{0};           // 画完且 swap 成功的次数（失败不再计数）
    std::uint64_t drop_no_display{0};   // 未挂载时被丢弃的帧数
    std::uint64_t drop_not_nv12{0};     // pixel_format 不是 NV12
    std::uint64_t drop_empty{0};        // nv12 数据为空
    std::uint64_t drop_zero_dim{0};     // frame.width/height 为 0
    std::uint64_t drop_too_small{0};    // nv12 字节数 < w*h*3/2
    std::uint64_t swap_failures{0};     // eglSwapBuffers 返回 EGL_FALSE
    std::uint64_t make_current_failures{0}; // eglMakeCurrent 失败（上下文没落在本线程）
    std::uint64_t reattach_attempts{0}; // 未挂载时的自愈重挂尝试次数（上限 12、间隔 ≥1s）

    // 最近一次绘制的现场
    std::int32_t last_gl_error{0};      // 绘制后 glGetError()（0 = 无错）
    std::int32_t last_egl_error{0};     // swap 失败后 eglGetError()（0 = 未失败过）
    std::uint32_t surface_width{0};     // eglQuerySurface 得到的 surface 尺寸
    std::uint32_t surface_height{0};    // （0 = 查询失败）
    std::uint32_t last_frame_w{0};
    std::uint32_t last_frame_h{0};
    std::uint32_t last_frame_bytes{0};  // 该帧 nv12 字节数
    std::uint32_t last_frame_format{0}; // 该帧 PixelFormat 数值
    std::uint32_t last_frame_stride{0};
    // attach 失败的确切原因（渲染器的 last_error）。为什么必须回传：
    // 上层虽然也把它写进了 Index.ets 的 hint，但 hint 只在预览区的状态遮罩里显示，
    // 而 AirPlay 镜像时遮罩是让开的 —— 等于"挂载失败的原因根本没法被看到"。
    char last_error[160]{0};
};

// 回读渲染链诊断（所有字段原子 relaxed 读；out 不能为 null）。
extern "C" void im_preview_renderer_diag(PreviewRendererDiag *out);

} // namespace iPhoneMirror::media
