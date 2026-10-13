#!/usr/bin/env python3
"""Inspect a built .app without changing it or contacting Apple's services."""
import json
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
extension = app / 'Contents/PlugIns/FinderExtension.appex'
action_extension = app / 'Contents/PlugIns/ActionExtension.appex'
creation_service = app / 'Contents/XPCServices/CreationService.xpc'

def plist(path):
    with path.open('rb') as source:
        return plistlib.load(source)

def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)

def require(condition, message):
    if not condition:
        raise SystemExit('FAIL: ' + message)

def icon_representations(path):
    # actool keeps extra resolutions in extension ICNS files; app ICNS may use Assets.car.
    data = path.read_bytes()
    require(data[:4] == b'icns' and int.from_bytes(data[4:8], 'big') == len(data), 'Invalid ICNS header')
    result = {}
    offset = 8
    while offset < len(data):
        size = int.from_bytes(data[offset + 4:offset + 8], 'big')
        require(size >= 8 and offset + size <= len(data), 'Invalid ICNS representation')
        result[data[offset:offset + 4]] = data[offset + 8:offset + size]
        offset += size
    require(bool(result), 'Empty icon')
    return result

bundles = {
    app: 'com.sapplex.RightClickText',
    extension: 'com.sapplex.RightClickText.FinderExtension',
    action_extension: 'com.sapplex.RightClickText.ActionExtension',
    creation_service: 'com.sapplex.RightClickText.CreationService',
}
require(all(bundle.is_dir() for bundle in bundles), 'Missing app, embedded extension, or CreationService.xpc')
command('codesign', '--verify', '--deep', '--strict', str(app))
report = []
app_group = plist(app / 'Contents/Info.plist')['RCTAppGroupIdentifier']
require(app_group == '8D9AHY5YW8.com.sapplex.RightClickText', 'Unexpected App Group identifier')
for bundle, identifier in bundles.items():
    info = plist(bundle / 'Contents/Info.plist')
    entitlements = plistlib.loads(command('codesign', '-d', '--entitlements', '-', '--xml', str(bundle)))
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    architectures = command('lipo', '-archs', str(executable)).decode().strip().split()
    require(set(architectures) == {'arm64', 'x86_64'}, 'Universal binary required: ' + str(bundle))
    require(info['CFBundleIdentifier'] == identifier, 'Bundle identifier mismatch: ' + str(bundle))
    require(info['CFBundleShortVersionString'] == '1.0.0' and info['CFBundleVersion'] == '11', 'Version mismatch: ' + str(bundle))
    require(info['LSMinimumSystemVersion'] == '13.0', 'Deployment target mismatch')
    require(entitlements.get('com.apple.security.app-sandbox') is True, 'Sandbox must be enabled')
    require(entitlements.get('com.apple.security.get-task-allow') is not True, 'Release must not permit debugging')
    allowed = {'com.apple.security.app-sandbox', 'com.apple.developer.team-identifier', 'com.apple.application-identifier'}
    if bundle == creation_service:
        # This process must not inherit or obtain the host's persistent folder capabilities.
        allowed.add('com.apple.security.files.user-selected.read-write')
        require(entitlements.get('com.apple.security.files.user-selected.read-write') is True, 'Worker needs user-selected read/write access')
        require('RCTAppGroupIdentifier' not in info, 'Worker must not configure an App Group')
        require(info.get('CFBundlePackageType') == 'XPC!', 'Invalid worker package type')
        configuration = info.get('XPCService', {})
        require(configuration.get('ServiceType') == 'Application', 'Worker must be an embedded application XPC service')
        require(configuration.get('JoinExistingSession') is True, 'Worker needs the user session pasteboard')
        require(configuration.get('RunLoopType') == 'NSRunLoop', 'Worker run loop mismatch')
    else:
        allowed.add('com.apple.security.application-groups')
        require(info.get('RCTAppGroupIdentifier') == app_group, 'Bundle App Group identifier mismatch')
        require(entitlements.get('com.apple.security.application-groups') == [app_group], 'App Group entitlement mismatch')
        if bundle == app:
            allowed.update({'com.apple.security.files.user-selected.read-write', 'com.apple.security.files.bookmarks.app-scope'})
    require(set(entitlements) <= allowed, 'Unexpected entitlements: ' + repr(set(entitlements) - allowed))
    if bundle in (extension, action_extension):
        require(info.get('CFBundlePackageType') == 'XPC!', 'Invalid extension package type')
        require(info.get('CFBundleIconFile') in ('AppIcon', 'AppIcon.icns'), 'Missing extension bundle icon declaration')
        require((bundle / 'Contents/Resources/AppIcon.icns').is_file(), 'Missing extension bundle icon')
        app_icons = icon_representations(app / 'Contents/Resources/AppIcon.icns')
        extension_icons = icon_representations(bundle / 'Contents/Resources/AppIcon.icns')
        require(all(extension_icons.get(kind) == content for kind, content in app_icons.items()), 'Extension icon representations must match containing app')
        require(isinstance(info.get('NSExtension', {}).get('NSExtensionPrincipalClass'), str) and bool(info['NSExtension']['NSExtensionPrincipalClass']), 'Missing extension principal class')
        if bundle == extension:
            require(info.get('LSUIElement') is True, 'Finder extension must declare LSUIElement=true (App Store 90360)')
        point = 'com.apple.FinderSync' if bundle == extension else 'com.apple.services'
        require(info['NSExtension']['NSExtensionPointIdentifier'] == point, 'Invalid extension point')
        if bundle == action_extension:
            require(info['NSExtension']['NSExtensionAttributes']['NSExtensionServiceAllowsFinderPreviewItem'] is True, 'Missing Finder Quick Action')
    elif bundle == app:
        require(entitlements.get('com.apple.security.files.user-selected.read-write') is True, 'Missing folder access entitlement')
        require(entitlements.get('com.apple.security.files.bookmarks.app-scope') is True, 'Missing private bookmark entitlement')
        require((bundle / 'Contents/Resources/AppIcon.icns').exists(), 'Missing app icon')
        services = info.get('NSServices', [])
        require(isinstance(services, list) and len(services) == 1, 'Exactly one Finder creation service is required')
        service = services[0]
        require(service.get('NSMessage') == 'createTextFile', 'Incorrect service selector')
        require(service.get('NSMenuItem') == {'default': 'New Text File'}, 'Incorrect service menu title')
        require(service.get('NSPortName') == 'RightClick Text', 'Incorrect service port name')
        require(service.get('NSRestricted') is False, 'Creation service must use the isolated sandbox-safe implementation')
        require(service.get('NSSendFileTypes') == ['public.directory'], 'Service must accept directory file URLs only')
        require('NSSendTypes' not in service, 'Service must not accept plain paths or broad pasteboard data')
        require(service.get('NSRequiredContext') == {'NSApplicationIdentifier': 'com.apple.finder'}, 'Service Finder context mismatch')
        require(str(service.get('NSTimeout')) == '15000', 'Service timeout mismatch')
        for locale, title in (('en', 'New Text File'), ('zh-Hans', '新建txt文本')):
            resource = bundle / f'Contents/Resources/{locale}.lproj/ServicesMenu.strings'
            require(resource.exists(), 'Missing localized Services menu')
            strings = json.loads(command('plutil', '-convert', 'json', '-o', '-', str(resource)))
            require(strings.get('New Text File') == title, 'Incorrect localized Services menu')
    privacy = plist(bundle / 'Contents/Resources/PrivacyInfo.xcprivacy')
    require(privacy['NSPrivacyTracking'] is False and privacy['NSPrivacyCollectedDataTypes'] == [], 'Privacy mismatch')
    require(privacy.get('NSPrivacyTrackingDomains', []) == [], 'Unexpected tracking domains')
    if bundle == creation_service:
        require(privacy['NSPrivacyAccessedAPITypes'] == [], 'Worker must not declare unused required-reason APIs')
    else:
        require(len(privacy['NSPrivacyAccessedAPITypes']) == 1, 'Unexpected required-reason API categories')
        api = privacy['NSPrivacyAccessedAPITypes'][0]
        require(api['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryFileTimestamp', 'Wrong API category')
        require(api['NSPrivacyAccessedAPITypeReasons'] == ['C617.1'], 'Incorrect required reasons')
        for locale in ('en', 'zh-Hans'):
            require((bundle / f'Contents/Resources/{locale}.lproj/Localizable.strings').exists(), 'Missing localization')
    report.append({'bundle': info['CFBundleIdentifier'], 'version': info['CFBundleShortVersionString'],
                   'build': info['CFBundleVersion'], 'architectures': architectures, 'sandbox': True,
                   'entitlements': entitlements, 'LSUIElement': info.get('LSUIElement')})
print(json.dumps({'result': 'PASS', 'artifacts': report}, ensure_ascii=False, indent=2))
