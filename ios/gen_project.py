#!/usr/bin/env python3
"""ios/Julglo.xcodeproj 생성 (앱 타깃 1개, 동기화 폴더 방식 — Julglo/ 안의 Swift 파일은 자동 포함)."""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
I = lambda n: f"1A00000000000000000000{n:02X}"

APP_ID = "kr.b-612.julglo"
DEPLOY = "18.0"


def settings_block(d: dict) -> str:
    return "\n".join(f"\t\t\t\t{k} = {v};" for k, v in d.items())


def target_settings() -> dict:
    return {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": '""',
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": "Config/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": '"줄글로"',
        "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.productivity"',
        "INFOPLIST_KEY_NSMicrophoneUsageDescription": '"회의를 녹음해 줄글로에 올릴 때 마이크를 사용해요."',
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
        "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": f'"{APP_ID}"',
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
        "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
        "SUPPORTS_MACCATALYST": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }


def project_settings(debug: bool) -> dict:
    s = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOY,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "SDKROOT": "iphoneos",
    }
    if debug:
        s.update({
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"',
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        })
    else:
        s.update({
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "VALIDATE_PRODUCT": "YES",
        })
    return s


def config(id_, name, settings):
    return f"""\t\t{id_} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings_block(settings)}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""


def phase(id_, isa, name):
    return f"""\t\t{id_} /* {name} */ = {{
\t\t\tisa = {isa};
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};"""


pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXFileReference section */
\t\t{I(0x01)} /* Julglo.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Julglo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{I(0x0B)} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
\t\t{I(0x02)} /* Julglo */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = Julglo; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
{phase(I(0x03), "PBXFrameworksBuildPhase", "Frameworks")}
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{I(0x04)} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I(0x02)} /* Julglo */,
\t\t\t\t{I(0x0A)} /* Config */,
\t\t\t\t{I(0x05)} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{I(0x0A)} /* Config */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I(0x0B)} /* Info.plist */,
\t\t\t);
\t\t\tpath = Config;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{I(0x05)} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{I(0x01)} /* Julglo.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{I(0x06)} /* Julglo */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {I(0x10)} /* Build configuration list for PBXNativeTarget "Julglo" */;
\t\t\tbuildPhases = (
\t\t\t\t{I(0x07)} /* Sources */,
\t\t\t\t{I(0x03)} /* Frameworks */,
\t\t\t\t{I(0x08)} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
\t\t\t\t{I(0x02)} /* Julglo */,
\t\t\t);
\t\t\tname = Julglo;
\t\t\tpackageProductDependencies = (
\t\t\t);
\t\t\tproductName = Julglo;
\t\t\tproductReference = {I(0x01)} /* Julglo.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{I(0x09)} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1600;
\t\t\t\tLastUpgradeCheck = 1600;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{I(0x06)} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {I(0x11)} /* Build configuration list for PBXProject "Julglo" */;
\t\t\tdevelopmentRegion = ko;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\tko,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {I(0x04)};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {I(0x05)} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{I(0x06)} /* Julglo */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
{phase(I(0x08), "PBXResourcesBuildPhase", "Resources")}
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
{phase(I(0x07), "PBXSourcesBuildPhase", "Sources")}
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
{config(I(0x12), "Debug", project_settings(True))}
{config(I(0x13), "Release", project_settings(False))}
{config(I(0x14), "Debug", target_settings())}
{config(I(0x15), "Release", target_settings())}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{I(0x11)} /* Build configuration list for PBXProject "Julglo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{I(0x12)} /* Debug */,
\t\t\t\t{I(0x13)} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{I(0x10)} /* Build configuration list for PBXNativeTarget "Julglo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{I(0x14)} /* Debug */,
\t\t\t\t{I(0x15)} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {I(0x09)} /* Project object */;
}}
"""

ref = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I(0x06)}" BuildableName = "Julglo.app" BlueprintName = "Julglo" ReferencedContainer = "container:Julglo.xcodeproj">\n            </BuildableReference>'
scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

proj = os.path.join(ROOT, "Julglo.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata", "xcschemes"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write(pbx)
open(os.path.join(proj, "xcshareddata", "xcschemes", "Julglo.xcscheme"), "w").write(scheme)
print("ok")
