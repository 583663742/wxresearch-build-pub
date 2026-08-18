# 微信聊天研究 1.0.1 — pkc 式微信内插件（macOS CI 构建）
# 注入微信进程(com.tencent.xin)，悬浮球 → 全屏聊天研究页面
# 会话列表 / 对话气泡 / 搜索 / 按天统计，实时只读微信沙盒 DB
#
# 关键约束（biaoji 历史踩坑，勿改）：
#   1. ARCHS=arm64e：arm64 构建缺 LC_DYLD_CHAINED_FIXUPS → dyld 拒绝加载
#   2. roothide scheme：路径 Library/ 无 var/jb 前缀
#   3. -lroothide 必须显式链接：注入 dylib 需 libroothide 初始化
#   4. -Wl,-fixup_chains 必须：arm64e iOS15+ 强制 chained fixups
#   5. llvm-strip 处理 arm64e chained fixups 崩溃 → TARGET_STRIP=true
export ARCHS = arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = roothide
export TARGET_STRIP = true

INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = wxresearch

wxresearch_FILES = Tweak.x
wxresearch_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
wxresearch_LDFLAGS = -lroothide -Wl,-fixup_chains -Wl,-s -framework WebKit -lsqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
