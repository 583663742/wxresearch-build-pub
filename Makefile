# 微信聊天研究 1.2.0 — pkc 式微信内插件（macOS CI 构建）
# 注入微信进程(com.tencent.xin)，长按+号 → pkc菜单 → 统计/AI/聊天记录
# 纯原生 UIKit，无悬浮球，零读库直到点击
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
wxresearch_LDFLAGS = -lroothide -Wl,-fixup_chains -Wl,-s -lsqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
