#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"
APP_NAME="Glance"
BUILD_DIR="${PROJECT_DIR}/.build/release"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"

echo "🔨 Building ${APP_NAME} in release mode..."
swift build -c release

echo "🧪 Running automated Glance QA & self-test suite..."
"${BUILD_DIR}/${APP_NAME}" --self-test

echo "📦 Assembling ${APP_NAME}.app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
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

echo "📲 Installing ${APP_NAME}.app to /Applications/${APP_NAME}.app..."
rm -rf "/Applications/${APP_NAME}.app"
cp -R "${APP_BUNDLE}" "/Applications/${APP_NAME}.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/${APP_NAME}.app" || true

if [ "${SIGN_IDENTITY}" = "-" ]; then
    tccutil reset Accessibility com.local.Glance || true
fi

echo "✅ Successfully created: ${APP_BUNDLE}"
echo "✅ Installed to: /Applications/${APP_NAME}.app"
echo "🚀 To run it, execute:"
echo "   open /Applications/${APP_NAME}.app"
