#!/usr/bin/env python3
"""Generate the checked-in native Xcode project without third-party dependencies."""
from pathlib import Path
from hashlib import sha1
import json

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def ident(value): return sha1(value.encode()).hexdigest()[:24].upper()
def add(key, isa, **values):
    uid = ident(key)
    objects[uid] = {"isa": isa, **values}
    return uid
def file(path, kind):
    return add("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="SOURCE_ROOT")
def build(key, ref, **extra): return add("build:" + key, "PBXBuildFile", fileRef=ref, **extra)
def phase(key, isa, files, **extra):
    return add("phase:" + key, isa, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0, **extra)
def configlist(name, values, project=False):
    entries = []
    for variant in ["Debug", "Release"]:
        settings = dict(values)
        if project:
            settings.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if variant == "Debug" else "-O", GCC_OPTIMIZATION_LEVEL="0" if variant == "Debug" else "s", DEBUG_INFORMATION_FORMAT="dwarf" if variant == "Debug" else "dwarf-with-dsym")
            if variant == "Debug": settings.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
        entries.append(add(name + ":" + variant, "XCBuildConfiguration", name=variant, buildSettings=settings))
    return add(name + ":configlist", "XCConfigurationList", buildConfigurations=entries, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

target_names = ["CaptureBridge", "RecorderCore", "AfterwordMCP", "Afterword", "RecorderCoreTests"]
target_ids = {name: ident("target:" + name) for name in target_names}
shortcut_package = add("package:KeyboardShortcuts", "XCLocalSwiftPackageReference", relativePath="Vendor/KeyboardShortcuts")
shortcut_product = add("package-product:KeyboardShortcuts", "XCSwiftPackageProductDependency", productName="KeyboardShortcuts")
lookback_package = add("package:Lookback", "XCRemoteSwiftPackageReference", repositoryURL="https://github.com/jbonatakis/lookback.git", requirement={"kind": "revision", "revision": "2a7979ee4cd5749a815f055d9a199211620d95a9"})
lookback_product = add("package-product:Lookback", "XCSwiftPackageProductDependency", package=lookback_package, productName="Lookback")
products = {}
product_kinds = {"CaptureBridge": ("libCaptureBridge.a", "archive.ar", "com.apple.product-type.library.static"), "RecorderCore": ("RecorderCore.framework", "wrapper.framework", "com.apple.product-type.framework"), "Afterword": ("Afterword.app", "wrapper.application", "com.apple.product-type.application"), "RecorderCoreTests": ("RecorderCoreTests.xctest", "wrapper.cfbundle", "com.apple.product-type.bundle.unit-test")}
product_kinds["AfterwordMCP"] = ("AfterwordMCP", "compiled.mach-o.executable", "com.apple.product-type.tool")
for name, (path, kind, _) in product_kinds.items():
    products[name] = add("product:" + name, "PBXFileReference", explicitFileType=kind, path=path, sourceTree="BUILT_PRODUCTS_DIR")

groups = []
for name in target_names:
    folder = ("Tests/" if name.endswith("Tests") else "Sources/") + name
    refs, compiled, headers = [], [], []
    for path in sorted((ROOT / folder).rglob("*")):
        if not path.is_file(): continue
        relative = str(path.relative_to(ROOT))
        kind = {".swift": "sourcecode.swift", ".c": "sourcecode.c.c", ".h": "sourcecode.c.h", ".modulemap": "sourcecode.module-map"}.get(path.suffix, "text")
        ref = file(relative, kind); refs.append(ref)
        if path.suffix in [".swift", ".c"]: compiled.append(build(relative, ref))
        if path.suffix == ".h": headers.append(build(relative, ref, settings={"ATTRIBUTES": ["Public"]}))
    groups.append(add("group:" + name, "PBXGroup", children=refs, name=name, sourceTree="<group>"))
    phases = [phase(name + ":sources", "PBXSourcesBuildPhase", compiled)]
    if headers: phases.append(phase(name + ":headers", "PBXHeadersBuildPhase", headers))
    dependencies, links = [], []
    deps = {"CaptureBridge": [], "RecorderCore": ["CaptureBridge"], "AfterwordMCP": ["RecorderCore"], "Afterword": ["RecorderCore", "AfterwordMCP"], "RecorderCoreTests": ["RecorderCore"]}[name]
    for dep in deps:
        proxy = add(name + ":proxy:" + dep, "PBXContainerItemProxy", containerPortal=ident("project"), proxyType=1, remoteGlobalIDString=target_ids[dep], remoteInfo=dep)
        dependencies.append(add(name + ":depends:" + dep, "PBXTargetDependency", target=target_ids[dep], targetProxy=proxy))
        if dep != "AfterwordMCP": links.append(build(name + ":link:" + dep, products[dep]))
    if name == "Afterword":
        links.append(add("build:KeyboardShortcuts", "PBXBuildFile", productRef=shortcut_product))
    if name == "RecorderCore":
        links.append(add("build:Lookback", "PBXBuildFile", productRef=lookback_product))
    phases.append(phase(name + ":frameworks", "PBXFrameworksBuildPhase", links))
    values = {"PRODUCT_NAME": name, "PRODUCT_BUNDLE_IDENTIFIER": "io.local.afterword." + name.lower(), "SKIP_INSTALL": "YES", "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_VERSION": "5.0"}
    if name == "RecorderCore":
        values.update(OTHER_LDFLAGS=["$(inherited)", "-lsqlite3"], DEFINES_MODULE="YES", MACH_O_TYPE="mh_dylib", DYLIB_INSTALL_NAME_BASE="@rpath", INSTALL_PATH="$(LOCAL_LIBRARY_DIR)/Frameworks")
    if name == "AfterwordMCP":
        values.update(PRODUCT_BUNDLE_IDENTIFIER="io.local.afterword.mcp", GENERATE_INFOPLIST_FILE="NO", ENABLE_HARDENED_RUNTIME="YES", OTHER_CODE_SIGN_FLAGS="--identifier io.local.afterword.mcp")
    if name == "Afterword":
        values.update(PRODUCT_NAME="Afterword", PRODUCT_MODULE_NAME="Afterword", EXECUTABLE_NAME="Afterword", PRODUCT_BUNDLE_IDENTIFIER="io.local.afterword", SKIP_INSTALL="NO", GENERATE_INFOPLIST_FILE="NO", INFOPLIST_FILE="Configuration/Info.plist", CODE_SIGN_ENTITLEMENTS="Configuration/Afterword.entitlements", ENABLE_HARDENED_RUNTIME="YES", ENABLE_APP_SANDBOX="NO")
        embed = build("embed:RecorderCore", products["RecorderCore"], settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
        phases.append(phase(name + ":embed", "PBXCopyFilesBuildPhase", [embed], dstPath="", dstSubfolderSpec=10, name="Embed Frameworks"))
        helper = build("embed:AfterwordMCP", products["AfterwordMCP"], settings={"ATTRIBUTES": ["CodeSignOnCopy"]})
        phases.append(phase(name + ":mcp", "PBXCopyFilesBuildPhase", [helper], dstPath="Contents/Helpers", dstSubfolderSpec=1, name="Embed MCP server"))
        phases.append(phase(name + ":transcription", "PBXShellScriptBuildPhase", [], name="Build local inference workers", shellPath="/bin/bash", shellScript='set -euo pipefail\ncd "$SRCROOT"\n./Scripts/build-transcription.sh\n./Scripts/build-embedding.sh\n./Scripts/build-diarization.sh\n./Scripts/embed-transcription.sh "$TARGET_BUILD_DIR/$WRAPPER_NAME"\n./Scripts/embed-embedding.sh "$TARGET_BUILD_DIR/$WRAPPER_NAME"\n./Scripts/embed-diarization.sh "$TARGET_BUILD_DIR/$WRAPPER_NAME"\n', alwaysOutOfDate=1))
        values.update(ENABLE_USER_SCRIPT_SANDBOXING="NO")
    if name == "RecorderCoreTests": values.update(TEST_HOST="", BUNDLE_LOADER="", LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@loader_path/../Frameworks", "$(BUILT_PRODUCTS_DIR)"])
    package_products = {"packageProductDependencies": [shortcut_product]} if name == "Afterword" else ({"packageProductDependencies": [lookback_product]} if name == "RecorderCore" else {})
    add("target:" + name, "PBXNativeTarget", buildConfigurationList=configlist(name, values), buildPhases=phases, buildRules=[], dependencies=dependencies, name=name, productName=values["PRODUCT_NAME"], productReference=products[name], productType=product_kinds[name][2], **package_products)

configuration = [file("Configuration/Info.plist", "text.plist.xml"), file("Configuration/Afterword.entitlements", "text.plist.entitlements"), file("Package.swift", "sourcecode.swift"), file("README.md", "net.daringfireball.markdown")]
groups.append(add("group:configuration", "PBXGroup", children=configuration, name="Configuration", sourceTree="<group>"))
product_group = add("group:products", "PBXGroup", children=list(products.values()), name="Products", sourceTree="<group>")
root_group = add("group:root", "PBXGroup", children=groups + [product_group], sourceTree="<group>")
project_settings = {"MACOSX_DEPLOYMENT_TARGET": "14.2", "SDKROOT": "macosx", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "GCC_C_LANGUAGE_STANDARD": "c11", "SWIFT_INCLUDE_PATHS": ["$(SRCROOT)/Sources/CaptureBridge/include"], "HEADER_SEARCH_PATHS": ["$(SRCROOT)/Sources/CaptureBridge/include"], "CODE_SIGN_IDENTITY": "Call Recorder Local Development", "CODE_SIGN_STYLE": "Manual", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"], "SWIFT_VERSION": "5.0"}
project = add("project", "PBXProject", attributes={"LastUpgradeCheck": "1600", "BuildIndependentTargetsInParallel": "YES"}, buildConfigurationList=configlist("project", project_settings, project=True), compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=root_group, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=list(target_ids.values()), packageReferences=[shortcut_package, lookback_package])

def plist(value, indent=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + json.dumps(str(k)) + " = " + plist(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
    if isinstance(value, list): return "(" + ", ".join(plist(v, indent) for v in value) + ")"
    if isinstance(value, int): return str(value)
    return json.dumps(value)

project_dir = ROOT / "Afterword.xcodeproj"
project_dir.mkdir(exist_ok=True)
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + plist({"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}) + "\n")
scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
def reference(name):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{product_kinds[name][0]}" BlueprintName="{name}" ReferencedContainer="container:Afterword.xcodeproj"/>'
(scheme_dir / "Afterword.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("Afterword")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference("RecorderCoreTests")}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference("Afterword")}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("Afterword")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated Afterword.xcodeproj and shared Afterword scheme")
