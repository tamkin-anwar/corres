"""Generate a dependency-free Xcode project from the checked-in native sources."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1]
def uid(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def q(value):
    return '"' + value + '"'

objects = []
def add(key, body):
    objects.append(f'{uid(key)} = {{ {body} }};')

sources = sorted(p.relative_to(root).as_posix() for folder in ['App', 'Core', 'DesignSystem', 'Features'] for p in (root / folder).glob('*.swift'))
resources = ['App/PrivacyInfo.xcprivacy', 'App/Assets.xcassets']
resource_kinds = {'App/Assets.xcassets': 'folder.assetcatalog'}
for path in sources + resources:
    kind = 'sourcecode.swift' if path.endswith('.swift') else resource_kinds.get(path, 'text.xml')
    add(path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')
    add('build:' + path, f'isa = PBXBuildFile; fileRef = {uid(path)};')
add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Corres.app; sourceTree = BUILT_PRODUCTS_DIR;')
add('products', f'isa = PBXGroup; children = ({uid("product")},); name = Products; sourceTree = "<group>";')
add('main', 'isa = PBXGroup; children = (' + ','.join(uid(p) for p in sources + resources) + ',' + uid('products') + ',); sourceTree = "<group>";')

# Swift Package dependencies. Xcode writes these directly into project.pbxproj
# when a package is added via File > Add Package Dependencies; since this
# script regenerates the whole file from scratch, they must be reproduced here
# too or every regeneration silently drops them (the same class of bug as the
# DEVELOPMENT_TEAM wipe above), breaking the build until re-added by hand.
packages = [
    {
        'key': 'GoogleSignIn-iOS',
        'url': 'https://github.com/google/GoogleSignIn-iOS',
        'minimumVersion': '10.0.0',
        'products': ['GoogleSignIn', 'GoogleSignInSwift'],
    },
]
package_product_uids = []
for pkg in packages:
    pkg_key = f'pkg:{pkg["key"]}'
    add(pkg_key, f'isa = XCRemoteSwiftPackageReference; repositoryURL = {q(pkg["url"])}; '
                 f'requirement = {{ kind = upToNextMajorVersion; minimumVersion = {pkg["minimumVersion"]}; }};')
    for product in pkg['products']:
        product_key = f'pkgproduct:{product}'
        add(product_key, f'isa = XCSwiftPackageProductDependency; package = {uid(pkg_key)}; productName = {product};')
        add(f'pkgbuild:{product}', f'isa = PBXBuildFile; productRef = {uid(product_key)};')
        package_product_uids.append(uid(product_key))

for key, kind, paths in [('sources', 'PBXSourcesBuildPhase', sources), ('resources', 'PBXResourcesBuildPhase', resources)]:
    add(key, f'isa = {kind}; buildActionMask = 2147483647; files = (' + ','.join(uid('build:' + p) for p in paths) + (',' if paths else '') + '); runOnlyForDeploymentPostprocessing = 0;')
framework_build_files = [f'pkgbuild:{p}' for pkg in packages for p in pkg['products']]
add('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ('
    + ','.join(uid(k) for k in framework_build_files) + (',' if framework_build_files else '')
    + '); runOnlyForDeploymentPostprocessing = 0;')
for mode in ['Debug', 'Release']:
    project_settings = 'CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete;'
    # Xcode writes this into project.pbxproj when a development team is picked
    # in Signing & Capabilities; since this script regenerates the whole file
    # from scratch, it must be baked in here too or every regeneration wipes
    # it and breaks on-device signing until it's manually re-picked.
    target_settings = 'DEVELOPMENT_TEAM = 7GGTC43CG8; PRODUCT_NAME = Corres; PRODUCT_BUNDLE_IDENTIFIER = studio.anwarcreative.corres; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_CFBundleDisplayName = Corres; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; INFOPLIST_FILE = App/Info.plist; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; TARGETED_DEVICE_FAMILY = 1; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 1; CODE_SIGN_STYLE = Automatic; SWIFT_EMIT_LOC_STRINGS = YES; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;'
    if mode == 'Debug':
        target_settings += ' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
    else:
        target_settings += ' SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
    for scope, settings in [('project', project_settings), ('target', target_settings)]:
        add(scope + mode, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {mode};')
for scope in ['project', 'target']:
    add(scope + 'configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(scope + "Debug")},{uid(scope + "Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")},); buildRules = (); dependencies = (); name = Corres; packageProductDependencies = (' + ','.join(package_product_uids) + (',' if package_product_uids else '') + f'); productName = Corres; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2700; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {uid("main")}; packageReferences = (' + ','.join(uid(f'pkg:{pkg["key"]}') for pkg in packages) + (',' if packages else '') + f'); productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")},);')
(root / 'Corres.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Corres.app" BlueprintName="Corres" ReferencedContainer="container:Corres.xcodeproj"/>'
(root / 'Corres.xcodeproj/xcshareddata/xcschemes/Corres.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated Corres.xcodeproj with {len(sources)} Swift sources.')
