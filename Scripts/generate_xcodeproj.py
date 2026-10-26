#!/usr/bin/env python3
"""Erzeugt Kompass.xcodeproj (macOS- und iOS-App aus denselben Quellen).

Der Ordner Sources/Kompass ist als „synchronisierte Gruppe“ eingebunden (Xcode 16+):
neue Swift-Dateien werden automatisch übernommen, das Projekt muss nicht neu erzeugt werden.
Aufruf: python3 Scripts/generate_xcodeproj.py
"""
import hashlib
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "Kompass.xcodeproj")


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


CAL = "Kompass synchronisiert deine Vorlesungen, Lernblöcke, Klausuren und Abgaben mit Apple Kalender und plant deine Woche um deine bestehenden Termine herum."
REM = "Kompass legt Erinnerungen für Klausuren, Abgaben und Präsentationen in der Erinnerungen-App an."

ids = {k: oid(k) for k in [
    "project", "mainGroup", "productsGroup", "xcodeGroup", "sourcesSync",
    "iosApp", "macApp", "iosAssets", "macAssets",
    "iosTarget", "macTarget",
    "iosSources", "iosFrameworks", "iosResources", "macSources", "macFrameworks", "macResources",
    "iosAssetsBuild", "macAssetsBuild",
    "projList", "projDebug", "projRelease",
    "iosList", "iosDebug", "iosRelease",
    "macList", "macDebug", "macRelease",
]}


def settings(d: dict, indent: str = "\t\t\t\t") -> str:
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            inner = "".join(f'{indent}\t"{x}",\n' for x in v)
            lines.append(f"{indent}{k} = (\n{inner}{indent});")
        else:
            s = str(v)
            needs_quotes = re.fullmatch(r"[A-Za-z0-9_./]+", s) is None
            lines.append(f'{indent}{k} = {chr(34) + s.replace(chr(34), chr(92) + chr(34)) + chr(34) if needs_quotes else s};')
    return "\n".join(lines)


common_project = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "SWIFT_VERSION": "5.0",
}
proj_debug = dict(common_project, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
proj_release = dict(common_project, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
})

common_target = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "2",
    "DEVELOPMENT_TEAM": "",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "Kompass",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.education",
    "INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription": CAL,
    "INFOPLIST_KEY_NSCalendarsUsageDescription": CAL,
    "INFOPLIST_KEY_NSRemindersFullAccessUsageDescription": REM,
    "INFOPLIST_KEY_NSRemindersUsageDescription": REM,
    "MARKETING_VERSION": "1.2",
    "PRODUCT_BUNDLE_IDENTIFIER": "de.staufer.kompass",
    "PRODUCT_NAME": "Kompass",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "5.0",
}
ios = dict(common_target, **{
    "DEVELOPMENT_TEAM": "J35PMHY434",  # Davids Personal Team (in Xcode gesetzt)
    "INFOPLIST_FILE": "Xcode/iOS/Info.plist",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "TARGETED_DEVICE_FAMILY": "1,2",
})
mac = dict(common_target, **{
    "CODE_SIGN_IDENTITY": "-",
    "COMBINE_HIDPI_IMAGES": "YES",
    "ENABLE_APP_SANDBOX": "NO",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "INFOPLIST_FILE": "Xcode/macOS/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": "macosx",
})

I = ids
pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{I['iosAssetsBuild']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {I['iosAssets']} /* Assets.xcassets */; }};
		{I['macAssetsBuild']} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {I['macAssets']} /* Assets.xcassets */; }};
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{I['iosApp']} /* Kompass.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Kompass.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['macApp']} /* Kompass.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Kompass.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['iosAssets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = "Assets.xcassets"; path = "iOS/Assets.xcassets"; sourceTree = "<group>"; }};
		{I['macAssets']} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; name = "Assets.xcassets"; path = "macOS/Assets.xcassets"; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['sourcesSync']} /* Kompass */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			name = Kompass;
			path = Sources/Kompass;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{I['iosFrameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['macFrameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{I['sourcesSync']} /* Kompass */,
				{I['xcodeGroup']} /* Xcode */,
				{I['productsGroup']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['xcodeGroup']} /* Xcode */ = {{
			isa = PBXGroup;
			children = (
				{I['iosAssets']} /* Assets.xcassets */,
				{I['macAssets']} /* Assets.xcassets */,
			);
			path = Xcode;
			sourceTree = "<group>";
		}};
		{I['productsGroup']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['iosApp']} /* Kompass.app */,
				{I['macApp']} /* Kompass.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['iosTarget']} /* Kompass iOS */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['iosList']} /* Build configuration list for PBXNativeTarget "Kompass iOS" */;
			buildPhases = (
				{I['iosSources']} /* Sources */,
				{I['iosFrameworks']} /* Frameworks */,
				{I['iosResources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['sourcesSync']} /* Kompass */,
			);
			name = "Kompass iOS";
			packageProductDependencies = (
			);
			productName = Kompass;
			productReference = {I['iosApp']} /* Kompass.app */;
			productType = "com.apple.product-type.application";
		}};
		{I['macTarget']} /* Kompass macOS */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['macList']} /* Build configuration list for PBXNativeTarget "Kompass macOS" */;
			buildPhases = (
				{I['macSources']} /* Sources */,
				{I['macFrameworks']} /* Frameworks */,
				{I['macResources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['sourcesSync']} /* Kompass */,
			);
			name = "Kompass macOS";
			packageProductDependencies = (
			);
			productName = Kompass;
			productReference = {I['macApp']} /* Kompass.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1620;
				LastUpgradeCheck = 1620;
				TargetAttributes = {{
					{I['iosTarget']} = {{
						CreatedOnToolsVersion = 16.2;
					}};
					{I['macTarget']} = {{
						CreatedOnToolsVersion = 16.2;
					}};
				}};
			}};
			buildConfigurationList = {I['projList']} /* Build configuration list for PBXProject "Kompass" */;
			developmentRegion = de;
			hasScannedForEncodings = 0;
			knownRegions = (
				de,
				Base,
			);
			mainGroup = {I['mainGroup']};
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['iosTarget']} /* Kompass iOS */,
				{I['macTarget']} /* Kompass macOS */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{I['iosResources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['iosAssetsBuild']} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['macResources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['macAssetsBuild']} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{I['iosSources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['macSources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{I['projDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(proj_debug)}
			}};
			name = Debug;
		}};
		{I['projRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(proj_release)}
			}};
			name = Release;
		}};
		{I['iosDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(ios)}
			}};
			name = Debug;
		}};
		{I['iosRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(dict(ios, VALIDATE_PRODUCT="YES"))}
			}};
			name = Release;
		}};
		{I['macDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(mac)}
			}};
			name = Debug;
		}};
		{I['macRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{settings(mac)}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{I['projList']} /* Build configuration list for PBXProject "Kompass" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['projDebug']} /* Debug */,
				{I['projRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['iosList']} /* Build configuration list for PBXNativeTarget "Kompass iOS" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['iosDebug']} /* Debug */,
				{I['iosRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['macList']} /* Build configuration list for PBXNativeTarget "Kompass macOS" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['macDebug']} /* Debug */,
				{I['macRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""


def scheme(target_id: str, name: str, run_config: str) -> str:
    ref = f'''<BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "Kompass.app"
               BlueprintName = "{name}"
               ReferencedContainer = "container:Kompass.xcodeproj">
            </BuildableReference>'''
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1620"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "{run_config}"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


os.makedirs(os.path.join(PROJ, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(PROJ, "project.pbxproj"), "w") as f:
    f.write(pbx)
# Auf dem iPhone die optimierte Version installieren (läuft flüssiger)
with open(os.path.join(PROJ, "xcshareddata", "xcschemes", "Kompass iOS.xcscheme"), "w") as f:
    f.write(scheme(ids["iosTarget"], "Kompass iOS", "Release"))
with open(os.path.join(PROJ, "xcshareddata", "xcschemes", "Kompass macOS.xcscheme"), "w") as f:
    f.write(scheme(ids["macTarget"], "Kompass macOS", "Release"))
print("Kompass.xcodeproj erzeugt")
