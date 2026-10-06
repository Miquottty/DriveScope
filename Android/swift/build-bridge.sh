#!/bin/zsh
# Builds DriveKit for Android (Swift SDK for Android, NDK r30) and drops the JNI library into the app.
#   Android/swift/build-bridge.sh
# Needs: swiftly's Swift 6.4.0 toolchain, the matching Swift SDK for Android, NDK 30 (docs/ANDROID_SPIKE.md).
set -euo pipefail
HERE="${0:A:h}"
SWIFT_VERSION=6.4.0
TOOLCHAIN="$HOME/Library/Developer/Toolchains/swift-$SWIFT_VERSION-RELEASE.xctoolchain"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/30.0.16248370}"
NDK_BIN=("$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin)
JNI_LIBS="$HERE/../app/src/main/jniLibs/arm64-v8a"

cd "$HERE/DriveKitBridge"
"$TOOLCHAIN/usr/bin/swift" build -c release --product DriveKitBridge \
  --swift-sdk "swift-$SWIFT_VERSION-RELEASE_android" --triple aarch64-unknown-linux-android28 --static-swift-stdlib
mkdir -p "$JNI_LIBS"
"$NDK_BIN[1]/llvm-strip" --strip-unneeded -o "$JNI_LIBS/libDriveKitBridge.so" \
  .build/out/Products/Release-android-aarch64/libDriveKitBridge.so
cp "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so "$JNI_LIBS/"
ls -la "$JNI_LIBS"
