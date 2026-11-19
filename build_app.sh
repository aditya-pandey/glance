#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"
APP_NAME="Glance"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
SKIP_INSTALL=false
PACKAGE_RELEASE=false

for arg in "$@"; do
    case "$arg" in
        --skip-install) SKIP_INSTALL=true ;;
        --package) PACKAGE_RELEASE=true ;;
    esac
done

echo "🔨 Building ${APP_NAME} Universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_BIN="${PROJECT_DIR}/.build/arm64-apple-macosx/release/${APP_NAME}"
X64_BIN="${PROJECT_DIR}/.build/x86_64-apple-macosx/release/${APP_NAME}"
UNIV_BIN="${PROJECT_DIR}/.build/${APP_NAME}-universal"
lipo -create -output "${UNIV_BIN}" "${ARM_BIN}" "${X64_BIN}"
chmod +x "${UNIV_BIN}"

echo "🧪 Running automated Glance QA & self-test suite..."
if [ "$(uname -m)" = "arm64" ]; then
    "${ARM_BIN}" --self-test
else
    "${X64_BIN}" --self-test
fi

echo "📦 Assembling ${APP_NAME}.app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${UNIV_BIN}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [ -f "${PROJECT_DIR}/Assets/LogoKit/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/Assets/LogoKit/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    cp "${PROJECT_DIR}/Assets/LogoKit/MenuBarTemplate.png" "${APP_BUNDLE}/Contents/Resources/MenuBarTemplate.png"
    cp "${PROJECT_DIR}/Assets/LogoKit/MenuBarTemplate@2x.png" "${APP_BUNDLE}/Contents/Resources/MenuBarTemplate@2x.png"
fi

cat << 'EOF' > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Glance</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.Glance</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Glance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>Glance needs Accessibility permissions to switch, inspect, close, and snap windows and detect Dock hover.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Glance uses Screen Recording to capture live visual thumbnail previews of your open windows.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Glance queries Chrome, Safari, and Arc to let you search and jump straight to open browser tabs.</string>
</dict>
</plist>
EOF

SIGN_IDENTITY="${GLANCE_SIGN_IDENTITY:-${WINDOWWHEEL_SIGN_IDENTITY:-}}"
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Glance Local|WindowWheel Local/ {print $2; exit}')
fi
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="-"
    echo "⚠️  Using ad-hoc code signing (-). Permissions must be re-granted after rebuilds until a 'Glance Local' or 'WindowWheel Local' certificate is created in Keychain Access."
else
    echo "✍️ Code signing ${APP_NAME}.app with identity: ${SIGN_IDENTITY}"
fi

codesign --force --deep --sign "${SIGN_IDENTITY}" --identifier "com.local.Glance" "${APP_BUNDLE}"

if [ "${SKIP_INSTALL}" = false ]; then
    echo "📲 Installing ${APP_NAME}.app to /Applications/${APP_NAME}.app..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "/Applications/${APP_NAME}.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/${APP_NAME}.app" || true

    if [ "${SIGN_IDENTITY}" = "-" ]; then
        tccutil reset Accessibility com.local.Glance || true
    fi
fi

if [ "${PACKAGE_RELEASE}" = true ]; then
    echo "🗜️  Packaging Glance-macOS-Universal.zip and Glance-macOS-Universal.dmg..."
    rm -f "${PROJECT_DIR}/Glance-macOS-Universal.zip" "${PROJECT_DIR}/Glance-macOS-Universal.dmg"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${PROJECT_DIR}/Glance-macOS-Universal.zip"
    STAGE_DIR="${PROJECT_DIR}/.build/dmg-stage"
    rm -rf "${STAGE_DIR}"
    mkdir -p "${STAGE_DIR}"
    cp -R "${APP_BUNDLE}" "${STAGE_DIR}/${APP_NAME}.app"
    ln -s /Applications "${STAGE_DIR}/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGE_DIR}" -ov -format UDZO "${PROJECT_DIR}/Glance-macOS-Universal.dmg" >/dev/null
    rm -rf "${STAGE_DIR}"
fi

echo "✅ Successfully created: ${APP_BUNDLE}"
if [ "${SKIP_INSTALL}" = false ]; then
    echo "✅ Installed to: /Applications/${APP_NAME}.app"
    echo "🚀 To run it, execute:"
    echo "   open /Applications/${APP_NAME}.app"
fi
