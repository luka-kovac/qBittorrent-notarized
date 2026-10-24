#!/usr/bin/env bash
set -euo pipefail

# Called inside upstream's packaging step, after macdeployqt and before hdiutil.
APP_PATH="${1:?Usage: notarize.sh APP.app}"
[[ "${APP_PATH}" == *.app && -d "${APP_PATH}" ]] || { echo "Missing app bundle: ${APP_PATH}" >&2; exit 1; }
appName="${APP_PATH%.app}"

SIGNING_TEMP="$(mktemp -d "${RUNNER_TEMP}/notarize.XXXXXX")"
CERTIFICATE_PATH="${SIGNING_TEMP}/build_certificate.p12"
KEYCHAIN_PATH="${SIGNING_TEMP}/app-signing.keychain-db"
ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"

cleanup() {
  if [[ -n "${ORIGINAL_DEFAULT_KEYCHAIN}" ]]; then
    security default-keychain -d user -s "${ORIGINAL_DEFAULT_KEYCHAIN}" >/dev/null 2>&1 || true
  fi
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1 || true
  rm -rf "${SIGNING_TEMP}"
}
trap cleanup EXIT

echo "${BUILD_CERTIFICATE_BASE64}" |
  base64 --decode > "${CERTIFICATE_PATH}"

if [[ ! -s "${CERTIFICATE_PATH}" ]]; then
  echo \
    "ERROR: Decoded certificate file is empty. Check BUILD_CERTIFICATE_BASE64." \
    >&2
  exit 1
fi

security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

security import "${CERTIFICATE_PATH}" \
  -P "${P12_PASSWORD}" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "${KEYCHAIN_PATH}"

# codesign requires the identity's keychain to be on the user search list,
# even when --keychain is supplied. Retain the runner's existing keychains.
EXISTING_KEYCHAINS=()
while IFS= read -r keychain; do
  EXISTING_KEYCHAINS+=("${keychain}")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
security list-keychains -d user -s "${KEYCHAIN_PATH}" "${EXISTING_KEYCHAINS[@]}"
security default-keychain -d user -s "${KEYCHAIN_PATH}"

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}"

echo "=== AVAILABLE SIGNING IDENTITIES IN CI RUNNER ==="
security find-identity -v -p codesigning "${KEYCHAIN_PATH}"
echo "================================================"

# Remove optional SQL plugins that can fail Apple's bundle-layout
# validation after deployment.
if [[ -d "${appName}.app/Contents/PlugIns/sqldrivers" ]]; then
  echo "Removing optional SQL plugins..."
  rm -rf "${appName}.app/Contents/PlugIns/sqldrivers"
fi

# Repair framework symlinks that macdeployqt can leave incomplete.
echo "Repairing internal framework symlinks..."
if [[ -d "${appName}.app/Contents/Frameworks" ]]; then
  for framework in "${appName}.app/Contents/Frameworks"/*.framework; do
    if [[ -d "${framework}" ]]; then
      fw_name="$(basename "${framework}" .framework)"

      if [[ -d "${framework}/Versions/A" ]] &&
        [[ ! -L "${framework}/Versions/Current" ]] &&
        [[ ! -d "${framework}/Versions/Current" ]]
      then
        ln -s A "${framework}/Versions/Current"
      fi

      if [[ ! -L "${framework}/${fw_name}" ]] &&
        [[ -f "${framework}/Versions/Current/${fw_name}" ]]
      then
        ln -s \
          "Versions/Current/${fw_name}" \
          "${framework}/${fw_name}"
      fi

      if [[ ! -L "${framework}/Resources" ]] &&
        [[ -d "${framework}/Versions/Current/Resources" ]]
      then
        ln -s \
          "Versions/Current/Resources" \
          "${framework}/Resources"
      fi
    fi
  done
fi

xattr -cr "${appName}.app"

SIGN_IDENTITY="Developer ID Application: ${DEVELOPER_NAME} (${TEAM_ID})"
echo "Signing with identity: ${SIGN_IDENTITY}"

if [[ -d "${appName}.app/Contents/PlugIns" ]]; then
  find "${appName}.app/Contents/PlugIns" \
    -type f \
    \( -name "*.dylib" -o -perm +111 \) \
    -exec codesign \
      --force \
      --options runtime \
      --timestamp \
      --keychain "${KEYCHAIN_PATH}" \
      --sign "${SIGN_IDENTITY}" \
      {} \;
fi

if [[ -d "${appName}.app/Contents/Frameworks" ]]; then
  find "${appName}.app/Contents/Frameworks" \
    -type f \
    \( -name "*.dylib" -o -name "*.framework" -o -perm +111 \) \
    -exec codesign \
      --force \
      --options runtime \
      --timestamp \
      --keychain "${KEYCHAIN_PATH}" \
      --sign "${SIGN_IDENTITY}" \
      {} \;
fi

codesign \
  --force \
  --options runtime \
  --timestamp \
  --keychain "${KEYCHAIN_PATH}" \
  --sign "${SIGN_IDENTITY}" \
  "${appName}.app/Contents/MacOS/${appName}"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --keychain "${KEYCHAIN_PATH}" \
  --sign "${SIGN_IDENTITY}" \
  "${appName}.app"

echo "Verifying signature structure..."
codesign --verify --deep --strict -v "${appName}.app"

echo "Packaging ZIP for Apple notarization..."
ditto -c -k --keepParent "${appName}.app" "${SIGNING_TEMP}/submission.zip"

echo "Submitting to Apple Notary Service..."
xcrun notarytool submit "${SIGNING_TEMP}/submission.zip" \
  --apple-id "${APPLE_ID}" \
  --password "${APP_SPECIFIC_PASSWORD}" \
  --team-id "${TEAM_ID}" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "${appName}.app"
xcrun stapler validate "${appName}.app"
