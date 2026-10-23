#!/usr/bin/env python3
"""Small, careful edits to Corres.xcodeproj, so new files and the Mac
target don't have to go through Xcode's UI.

    Scripts/pbxtool.py add-mac-target
    Scripts/pbxtool.py add-watch-app
    Scripts/pbxtool.py add-watch-widgets
    Scripts/pbxtool.py add-sources <TargetName> <path> [<path> ...]
    Scripts/pbxtool.py remove-sources <TargetName> <path> [<path> ...]
    Scripts/pbxtool.py add-resources <TargetName> <path> [<path> ...]

Paths are relative to the repository root (sourceTree SOURCE_ROOT, the way
every existing file is referenced). IDs are derived from what they name, so
running a command twice changes nothing.
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBX = ROOT / "Corres.xcodeproj" / "project.pbxproj"
TEAM = "7GGTC43CG8"


def uid(*parts: str) -> str:
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def insert_in_section(text: str, section: str, entry: str) -> str:
    marker = f"/* End {section} section */"
    if marker not in text:
        begin = "/* Begin XCBuildConfiguration section */"
        text = text.replace(begin, f"/* Begin {section} section */\n/* End {section} section */\n\n{begin}", 1)
    return text.replace(marker, entry + marker, 1)


def append_to_list(text: str, owner_id: str, key: str, item: str) -> str:
    """Adds `item` to the `key = ( ... );` list inside the object `owner_id`."""
    start = text.index(f"\t\t{owner_id} ")
    open_at = text.index(f"{key} = (", start)
    close_at = text.index(");", open_at)
    if item.split(" ")[0] in text[open_at:close_at]:
        return text
    return text[:close_at] + f"\t{item},\n\t\t\t" + text[close_at:]


def file_ref(text: str, path: str) -> tuple[str, str]:
    m = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(path) + r" \*/ = \{isa = PBXFileReference;", text)
    if m:
        return text, m.group(1)
    ref = uid("ref", path)
    kind = {"swift": "sourcecode.swift", "plist": "text.plist.xml", "entitlements": "text.plist.entitlements",
            "xcassets": "folder.assetcatalog", "icon": "folder.iconcomposer.icon"}.get(path.rsplit(".", 1)[-1], "text")
    entry = f"\t\t{ref} /* {path} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {path}; sourceTree = SOURCE_ROOT; }};\n"
    text = insert_in_section(text, "PBXFileReference", entry)
    main = re.search(r"mainGroup = ([0-9A-F]{24});", text).group(1)
    text = append_to_list(text, main + " =", "children", f"{ref} /* {path} */")
    return text, ref


def target_id(text: str, name: str) -> str:
    m = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(name) + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", text)
    if not m:
        sys.exit(f"No target named {name}")
    return m.group(1)


def phase_id(text: str, target: str, phase: str) -> str:
    start = text.index(f"\t\t{target} /*")
    block = text[start:text.index("};", text.index("buildPhases", start))]
    return re.search(r"([0-9A-F]{24}) /\* " + phase + r" \*/", block).group(1)


def add_sources(text: str, target_name: str, paths: list[str]) -> str:
    target = target_id(text, target_name)
    sources = phase_id(text, target, "Sources")
    for path in paths:
        text, ref = file_ref(text, path)
        build = uid("build", target_name, path)
        if build in text:
            continue
        text = insert_in_section(
            text, "PBXBuildFile",
            f"\t\t{build} /* {path} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path} */; }};\n")
        text = append_to_list(text, sources + " /* Sources */ =", "files", f"{build} /* {path} in Sources */")
    return text


def add_resources(text: str, target_name: str, paths: list[str]) -> str:
    target = target_id(text, target_name)
    resources = phase_id(text, target, "Resources")
    for path in paths:
        text, ref = file_ref(text, path)
        build = uid("build", target_name, path, "resources")
        if build in text:
            continue
        text = insert_in_section(
            text, "PBXBuildFile",
            f"\t\t{build} /* {path} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {path} */; }};\n")
        text = append_to_list(text, resources + " /* Resources */ =", "files", f"{build} /* {path} in Resources */")
    return text


def remove_sources(text: str, target_name: str, paths: list[str]) -> str:
    for path in paths:
        build = uid("build", target_name, path)
        text = re.sub(r"\t*" + build + r" /\*[^\n]*\n", "", text)
    return text


def settings(entries: dict) -> str:
    lines = []
    for key, value in entries.items():
        if isinstance(value, list):
            inner = "".join(f"\t\t\t\t\t{v},\n" for v in value)
            lines.append(f"\t\t\t\t{key} = (\n{inner}\t\t\t\t);")
        else:
            lines.append(f"\t\t\t\t{key} = {value};")
    return "\n".join(lines)


def add_mac_target(text: str) -> str:
    name = "CorresMac"
    if f"/* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;" in text:
        return text
    target, product = uid("target", name), uid("product", name)
    sources, frameworks, resources = uid("sources", name), uid("frameworks", name), uid("resources", name)
    config_list, debug, release = uid("configlist", name), uid("debug", name), uid("release", name)
    google = uid("dep", name, "GoogleSignIn")
    postwright = uid("dep", name, "Postwright")
    google_fw, postwright_fw = uid("fw", name, "GoogleSignIn"), uid("fw", name, "Postwright")
    assets_build = uid("build", name, "App/Assets.xcassets")
    privacy_build = uid("build", name, "App/PrivacyInfo.xcprivacy")

    text = insert_in_section(text, "PBXFileReference",
        f"\t\t{product} /* Corres.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Corres.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    text = append_to_list(text, "0A3E27B8CA818264D75C8D81 /* Products */ =", "children", f"{product} /* Corres.app */")
    text = insert_in_section(text, "PBXBuildFile",
        f"\t\t{google_fw} /* GoogleSignIn in Frameworks */ = {{isa = PBXBuildFile; productRef = {google} /* GoogleSignIn */; }};\n"
        f"\t\t{postwright_fw} /* Postwright in Frameworks */ = {{isa = PBXBuildFile; productRef = {postwright} /* Postwright */; }};\n"
        f"\t\t{assets_build} /* App/Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = B16B6325BA8F1CFBCC279108 /* App/Assets.xcassets */; }};\n"
        f"\t\t{privacy_build} /* App/PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = F048BFA7B57836F484F1B9C1 /* App/PrivacyInfo.xcprivacy */; }};\n")
    text = insert_in_section(text, "XCSwiftPackageProductDependency",
        f"\t\t{google} /* GoogleSignIn */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = 362DCEECAB286DF675BE4C19 /* XCRemoteSwiftPackageReference \"GoogleSignIn-iOS\" */;\n"
        f"\t\t\tproductName = GoogleSignIn;\n\t\t}};\n"
        f"\t\t{postwright} /* Postwright */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
        f"\t\t\tpackage = A1C0DE0000000000000E0001 /* XCLocalSwiftPackageReference \"Packages/Postwright\" */;\n"
        f"\t\t\tproductName = Postwright;\n\t\t}};\n")
    text = insert_in_section(text, "PBXSourcesBuildPhase",
        f"\t\t{sources} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXFrameworksBuildPhase",
        f"\t\t{frameworks} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{google_fw} /* GoogleSignIn in Frameworks */,\n\t\t\t\t{postwright_fw} /* Postwright in Frameworks */,\n"
        f"\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXResourcesBuildPhase",
        f"\t\t{resources} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{assets_build} /* App/Assets.xcassets in Resources */,\n\t\t\t\t{privacy_build} /* App/PrivacyInfo.xcprivacy in Resources */,\n"
        f"\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXNativeTarget",
        f"\t\t{target} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{sources} /* Sources */,\n\t\t\t\t{frameworks} /* Frameworks */,\n\t\t\t\t{resources} /* Resources */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {name};\n"
        f"\t\t\tpackageProductDependencies = (\n\t\t\t\t{google} /* GoogleSignIn */,\n\t\t\t\t{postwright} /* Postwright */,\n\t\t\t);\n"
        f"\t\t\tproductName = Corres;\n\t\t\tproductReference = {product} /* Corres.app */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n")
    text = append_to_list(text, "244210E48437B6556980A702 /* Project object */ =", "targets", f"{target} /* {name} */")

    common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "Mac/CorresMac.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "16",
        "DEVELOPMENT_TEAM": TEAM,
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Mac/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Corres",
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.productivity"',
        "INFOPLIST_KEY_NSContactsUsageDescription": '"Corres suggests people from your Contacts as you address an email and shows their photos beside their mail. Your contacts stay on this Mac."',
        "INFOPLIST_KEY_NSHumanReadableCopyright": '"© 2026 Anwar Creative Studio"',
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/../Frameworks"'],
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "MARKETING_VERSION": "0.2.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.anwarcreative.corres",
        "PRODUCT_NAME": "Corres",
        "SDKROOT": "macosx",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    debug_settings = dict(common, ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS='"DEBUG $(inherited)"', SWIFT_OPTIMIZATION_LEVEL='"-Onone"')
    release_settings = dict(common, DEBUG_INFORMATION_FORMAT='"dwarf-with-dsym"', SWIFT_OPTIMIZATION_LEVEL='"-O"')
    text = insert_in_section(text, "XCBuildConfiguration",
        f"\t\t{debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(debug_settings)}\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
        f"\t\t{release} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(release_settings)}\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n")
    text = insert_in_section(text, "XCConfigurationList",
        f"\t\t{config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n\t\t\t\t{debug} /* Debug */,\n\t\t\t\t{release} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
    for path in ["Mac/Info.plist", "Mac/CorresMac.entitlements"]:
        text, _ = file_ref(text, path)
    return text


def add_mac_widgets(text: str) -> str:
    """The desktop widgets for Corres for Mac: the iPhone widgets' code in
    a macOS extension, embedded in CorresMac."""
    name = "CorresMacWidgets"
    if f"/* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;" in text:
        return text
    mac = target_id(text, "CorresMac")
    target, product = uid("target", name), uid("product", name)
    sources, frameworks, resources = uid("sources", name), uid("frameworks", name), uid("resources", name)
    config_list, debug, release = uid("configlist", name), uid("debug", name), uid("release", name)
    embed_phase, embed_file = uid("embed", name), uid("embedfile", name)
    proxy, dependency = uid("proxy", name), uid("dependency", name)

    text = insert_in_section(text, "PBXFileReference",
        f"\t\t{product} /* {name}.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = {name}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    text = append_to_list(text, "0A3E27B8CA818264D75C8D81 /* Products */ =", "children", f"{product} /* {name}.appex */")
    text = insert_in_section(text, "PBXSourcesBuildPhase",
        f"\t\t{sources} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXFrameworksBuildPhase",
        f"\t\t{frameworks} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXResourcesBuildPhase",
        f"\t\t{resources} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXNativeTarget",
        f"\t\t{target} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{sources} /* Sources */,\n\t\t\t\t{frameworks} /* Frameworks */,\n\t\t\t\t{resources} /* Resources */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {name};\n"
        f"\t\t\tproductName = {name};\n\t\t\tproductReference = {product} /* {name}.appex */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.app-extension\";\n\t\t}};\n")
    text = append_to_list(text, "244210E48437B6556980A702 /* Project object */ =", "targets", f"{target} /* {name} */")

    # Built before, and embedded in, the Mac app.
    text = insert_in_section(text, "PBXContainerItemProxy",
        f"\t\t{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = 244210E48437B6556980A702 /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {target};\n\t\t\tremoteInfo = {name};\n\t\t}};\n")
    text = insert_in_section(text, "PBXTargetDependency",
        f"\t\t{dependency} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {target} /* {name} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};\n")
    text = append_to_list(text, f"{mac} /* CorresMac */ =", "dependencies", f"{dependency} /* PBXTargetDependency */")
    text = insert_in_section(text, "PBXBuildFile",
        f"\t\t{embed_file} /* {name}.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {product} /* {name}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
    text = insert_in_section(text, "PBXCopyFilesBuildPhase",
        f"\t\t{embed_phase} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{embed_file} /* {name}.appex in Embed Foundation Extensions */,\n\t\t\t);\n"
        f"\t\t\tname = \"Embed Foundation Extensions\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = append_to_list(text, f"{mac} /* CorresMac */ =", "buildPhases", f"{embed_phase} /* Embed Foundation Extensions */")

    common = {
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_ENTITLEMENTS": "Widgets/CorresMacWidgets.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "18",
        "DEVELOPMENT_TEAM": TEAM,
        "ENABLE_HARDENED_RUNTIME": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Widgets/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Corres",
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/../Frameworks"', '"@executable_path/../../../../Frameworks"'],
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "MARKETING_VERSION": "0.2.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.anwarcreative.corres.widgets",
        "PRODUCT_NAME": name,
        "SDKROOT": "macosx",
        "SKIP_INSTALL": "YES",
        "SUPPORTED_PLATFORMS": "macosx",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    debug_settings = dict(common, ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS='"DEBUG $(inherited)"', SWIFT_OPTIMIZATION_LEVEL='"-Onone"')
    release_settings = dict(common, SWIFT_OPTIMIZATION_LEVEL='"-O"')
    text = insert_in_section(text, "XCBuildConfiguration",
        f"\t\t{debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(debug_settings)}\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
        f"\t\t{release} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(release_settings)}\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n")
    text = insert_in_section(text, "XCConfigurationList",
        f"\t\t{config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n\t\t\t\t{debug} /* Debug */,\n\t\t\t\t{release} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
    text, _ = file_ref(text, "Widgets/CorresMacWidgets.entitlements")
    return text


def add_watch_widgets(text: str) -> str:
    """Corres on the watch face and in the Smart Stack: a watchOS widget
    extension, embedded in CorresWatch."""
    name = "CorresWatchWidgets"
    if f"/* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;" in text:
        return text
    mac = target_id(text, "CorresWatch")
    target, product = uid("target", name), uid("product", name)
    sources, frameworks, resources = uid("sources", name), uid("frameworks", name), uid("resources", name)
    config_list, debug, release = uid("configlist", name), uid("debug", name), uid("release", name)
    embed_phase, embed_file = uid("embed", name), uid("embedfile", name)
    proxy, dependency = uid("proxy", name), uid("dependency", name)

    text = insert_in_section(text, "PBXFileReference",
        f"\t\t{product} /* {name}.appex */ = {{isa = PBXFileReference; explicitFileType = \"wrapper.app-extension\"; includeInIndex = 0; path = {name}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    text = append_to_list(text, "0A3E27B8CA818264D75C8D81 /* Products */ =", "children", f"{product} /* {name}.appex */")
    text = insert_in_section(text, "PBXSourcesBuildPhase",
        f"\t\t{sources} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXFrameworksBuildPhase",
        f"\t\t{frameworks} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXResourcesBuildPhase",
        f"\t\t{resources} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXNativeTarget",
        f"\t\t{target} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{sources} /* Sources */,\n\t\t\t\t{frameworks} /* Frameworks */,\n\t\t\t\t{resources} /* Resources */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {name};\n"
        f"\t\t\tproductName = {name};\n\t\t\tproductReference = {product} /* {name}.appex */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.app-extension\";\n\t\t}};\n")
    text = append_to_list(text, "244210E48437B6556980A702 /* Project object */ =", "targets", f"{target} /* {name} */")

    # Built before, and embedded in, the Watch app.
    text = insert_in_section(text, "PBXContainerItemProxy",
        f"\t\t{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = 244210E48437B6556980A702 /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {target};\n\t\t\tremoteInfo = {name};\n\t\t}};\n")
    text = insert_in_section(text, "PBXTargetDependency",
        f"\t\t{dependency} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {target} /* {name} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};\n")
    text = append_to_list(text, f"{mac} /* CorresWatch */ =", "dependencies", f"{dependency} /* PBXTargetDependency */")
    text = insert_in_section(text, "PBXBuildFile",
        f"\t\t{embed_file} /* {name}.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {product} /* {name}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
    text = insert_in_section(text, "PBXCopyFilesBuildPhase",
        f"\t\t{embed_phase} /* Embed Foundation Extensions */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{embed_file} /* {name}.appex in Embed Foundation Extensions */,\n\t\t\t);\n"
        f"\t\t\tname = \"Embed Foundation Extensions\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = append_to_list(text, f"{mac} /* CorresWatch */ =", "buildPhases", f"{embed_phase} /* Embed Foundation Extensions */")

    current = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", text).group(1)
    common = {
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_ENTITLEMENTS": "WatchWidgets/CorresWatchWidgets.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": current,
        "DEVELOPMENT_TEAM": TEAM,
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "WatchWidgets/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Corres",
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"', '"@executable_path/../../Frameworks"'],
        "MARKETING_VERSION": "0.2.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.anwarcreative.corres.watchkitapp.widgets",
        "PRODUCT_NAME": name,
        "SDKROOT": "watchos",
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "4",
        "WATCHOS_DEPLOYMENT_TARGET": "10.0",
    }
    debug_settings = dict(common, ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS='"DEBUG $(inherited)"', SWIFT_OPTIMIZATION_LEVEL='"-Onone"')
    release_settings = dict(common, SWIFT_OPTIMIZATION_LEVEL='"-O"')
    text = insert_in_section(text, "XCBuildConfiguration",
        f"\t\t{debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(debug_settings)}\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
        f"\t\t{release} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(release_settings)}\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n")
    text = insert_in_section(text, "XCConfigurationList",
        f"\t\t{config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n\t\t\t\t{debug} /* Debug */,\n\t\t\t\t{release} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
    for path in ["WatchWidgets/CorresWatchWidgets.entitlements", "WatchWidgets/Info.plist", "Watch/CorresWatch.entitlements"]:
        text, _ = file_ref(text, path)
    # The Watch app shares an App Group with it.
    for config in re.findall(r"(\w{24}) /\* (?:Debug|Release) \*/,", re.search(r"/\* Build configuration list for PBXNativeTarget \"CorresWatch\" \*/ = \{.*?\};", text, re.S).group(0)):
        text = re.sub(rf"({config} /\* (?:Debug|Release) \*/ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n)", r"\1\t\t\t\tCODE_SIGN_ENTITLEMENTS = Watch/CorresWatch.entitlements;\n", text)
    return text


def add_watch_app(text: str) -> str:
    """Corres for Apple Watch: a watchOS app embedded in the iPhone app,
    talking to it through WatchConnectivity."""
    name = "CorresWatch"
    if f"/* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;" in text:
        return text
    phone = target_id(text, "Corres")
    target, product = uid("target", name), uid("product", name)
    sources, frameworks, resources = uid("sources", name), uid("frameworks", name), uid("resources", name)
    config_list, debug, release = uid("configlist", name), uid("debug", name), uid("release", name)
    embed_phase, embed_file = uid("embed", name), uid("embedfile", name)
    proxy, dependency = uid("proxy", name), uid("dependency", name)

    text = insert_in_section(text, "PBXFileReference",
        f"\t\t{product} /* {name}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {name}.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
    text = append_to_list(text, "0A3E27B8CA818264D75C8D81 /* Products */ =", "children", f"{product} /* {name}.app */")
    for phase, isa, label in [(sources, "PBXSourcesBuildPhase", "Sources"), (frameworks, "PBXFrameworksBuildPhase", "Frameworks"),
                              (resources, "PBXResourcesBuildPhase", "Resources")]:
        text = insert_in_section(text, isa,
            f"\t\t{phase} /* {label} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n"
            f"\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = insert_in_section(text, "PBXNativeTarget",
        f"\t\t{target} /* {name} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{sources} /* Sources */,\n\t\t\t\t{frameworks} /* Frameworks */,\n\t\t\t\t{resources} /* Resources */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {name};\n"
        f"\t\t\tproductName = {name};\n\t\t\tproductReference = {product} /* {name}.app */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t}};\n")
    text = append_to_list(text, "244210E48437B6556980A702 /* Project object */ =", "targets", f"{target} /* {name} */")

    # Built before, and embedded in, the iPhone app.
    text = insert_in_section(text, "PBXContainerItemProxy",
        f"\t\t{proxy} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = 244210E48437B6556980A702 /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {target};\n\t\t\tremoteInfo = {name};\n\t\t}};\n")
    text = insert_in_section(text, "PBXTargetDependency",
        f"\t\t{dependency} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {target} /* {name} */;\n\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;\n\t\t}};\n")
    text = append_to_list(text, f"{phone} /* Corres */ =", "dependencies", f"{dependency} /* PBXTargetDependency */")
    text = insert_in_section(text, "PBXBuildFile",
        f"\t\t{embed_file} /* {name}.app in Embed Watch Content */ = {{isa = PBXBuildFile; fileRef = {product} /* {name}.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n")
    text = insert_in_section(text, "PBXCopyFilesBuildPhase",
        f"\t\t{embed_phase} /* Embed Watch Content */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tdstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";\n\t\t\tdstSubfolderSpec = 16;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{embed_file} /* {name}.app in Embed Watch Content */,\n\t\t\t);\n"
        f"\t\t\tname = \"Embed Watch Content\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
    text = append_to_list(text, f"{phone} /* Corres */ =", "buildPhases", f"{embed_phase} /* Embed Watch Content */")

    current = re.search(r"CURRENT_PROJECT_VERSION = (\d+);", text).group(1)
    common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": current,
        "DEVELOPMENT_TEAM": TEAM,
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Corres",
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"',
        "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": "studio.anwarcreative.corres",
        "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp": "NO",
        "LD_RUNPATH_SEARCH_PATHS": ['"$(inherited)"', '"@executable_path/Frameworks"'],
        "MARKETING_VERSION": "0.2.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "studio.anwarcreative.corres.watchkitapp",
        "PRODUCT_NAME": name,
        "SDKROOT": "watchos",
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "4",
        "WATCHOS_DEPLOYMENT_TARGET": "10.0",
    }
    debug_settings = dict(common, ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS='"DEBUG $(inherited)"', SWIFT_OPTIMIZATION_LEVEL='"-Onone"')
    release_settings = dict(common, SWIFT_OPTIMIZATION_LEVEL='"-O"')
    text = insert_in_section(text, "XCBuildConfiguration",
        f"\t\t{debug} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(debug_settings)}\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n"
        f"\t\t{release} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings(release_settings)}\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n")
    text = insert_in_section(text, "XCConfigurationList",
        f"\t\t{config_list} /* Build configuration list for PBXNativeTarget \"{name}\" */ = {{\n\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n\t\t\t\t{debug} /* Debug */,\n\t\t\t\t{release} /* Release */,\n\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
    return text


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    text = PBX.read_text()
    command, args = sys.argv[1], sys.argv[2:]
    if command == "add-mac-target":
        text = add_mac_target(text)
    elif command == "add-mac-widgets":
        text = add_mac_widgets(text)
    elif command == "add-watch-app":
        text = add_watch_app(text)
    elif command == "add-watch-widgets":
        text = add_watch_widgets(text)
    elif command == "add-sources":
        text = add_sources(text, args[0], args[1:])
    elif command == "add-resources":
        text = add_resources(text, args[0], args[1:])
    elif command == "remove-sources":
        text = remove_sources(text, args[0], args[1:])
    else:
        sys.exit(__doc__)
    PBX.write_text(text)


if __name__ == "__main__":
    main()
