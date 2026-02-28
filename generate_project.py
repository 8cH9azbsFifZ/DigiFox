#!/usr/bin/env python3
"""Generate DigiFox.xcodeproj/project.pbxproj from the DigiFox/ source tree."""

import hashlib
import os
import sys

# ---------------------------------------------------------------------------
# Deterministic GUID generation (same approach as the original projects)
# ---------------------------------------------------------------------------

def guid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

# ---------------------------------------------------------------------------
# Scan source tree
# ---------------------------------------------------------------------------

SOURCE_DIR = "DigiFox"
FRAMEWORKS_DIR = "Frameworks"
PROJECT_NAME = "DigiFox"
BUNDLE_ID = "com.digifox.ios"
TEAM_ID = ""  # set your team ID here or leave empty

def scan_sources(root):
    swift, objc_m, objc_h, c_files, assets = [], [], [], [], []
    for dirpath, _, filenames in os.walk(root):
        for f in filenames:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, ".")
            if f.endswith(".swift"):
                swift.append(rel)
            elif f.endswith(".m"):
                objc_m.append(rel)
            elif f.endswith(".h"):
                objc_h.append(rel)
            elif f.endswith(".c"):
                c_files.append(rel)
            elif f == "Contents.json":
                # part of asset catalog
                pass
    # Asset catalogs
    for dirpath, dirs, _ in os.walk(root):
        for d in dirs:
            if d.endswith(".xcassets"):
                assets.append(os.path.relpath(os.path.join(dirpath, d), "."))
    return swift, objc_m, objc_h, c_files, assets

swift_files, objc_m_files, objc_h_files, c_files, asset_catalogs = scan_sources(SOURCE_DIR)
all_source_files = swift_files + objc_m_files + c_files

# Sort for deterministic output
swift_files.sort()
objc_m_files.sort()
objc_h_files.sort()
c_files.sort()
all_source_files.sort()

# ---------------------------------------------------------------------------
# GUIDs
# ---------------------------------------------------------------------------

PROJECT_GUID     = guid("project")
MAIN_GROUP       = guid("mainGroup")
SOURCE_GROUP     = guid("sourceGroup")
FRAMEWORKS_GROUP = guid("frameworksGroup")
PRODUCTS_GROUP   = guid("productsGroup")
TARGET_GUID      = guid("target_DigiFox")
APP_PRODUCT      = guid("product_DigiFox.app")
CONFIG_LIST_PROJ = guid("configList_project")
CONFIG_LIST_TGT  = guid("configList_target")
CONFIG_DEBUG_P   = guid("config_debug_project")
CONFIG_RELEASE_P = guid("config_release_project")
CONFIG_DEBUG_T   = guid("config_debug_target")
CONFIG_RELEASE_T = guid("config_release_target")
SOURCES_PHASE    = guid("sources_phase")
FRAMEWORKS_PHASE = guid("frameworks_phase")
RESOURCES_PHASE  = guid("resources_phase")
NATIVE_TARGET    = guid("native_target")

# Hamlib framework
HAMLIB_FW_FILE   = guid("hamlib_fw_file")
HAMLIB_FW_BUILD  = guid("hamlib_fw_build")
HAMLIB_FW_EMBED  = guid("hamlib_fw_embed")
EMBED_FW_PHASE   = guid("embed_fw_phase")

# Entitlements
ENTITLEMENTS_FILE = guid("entitlements_file")

# Info.plist
INFOPLIST_FILE   = guid("infoplist_file")

# Bridging header
BRIDGING_HEADER  = "DigiFox/DigiFox-Bridging-Header.h"

# ---------------------------------------------------------------------------
# Build file references and build phases
# ---------------------------------------------------------------------------

file_refs = {}   # path -> fileRef GUID
build_files = {} # path -> buildFile GUID
groups = {}      # group_path -> (group_guid, children_guids)

def add_file(path):
    fr = guid(f"fileRef_{path}")
    bf = guid(f"buildFile_{path}")
    file_refs[path] = fr
    build_files[path] = bf
    return fr, bf

for f in all_source_files:
    add_file(f)
for f in objc_h_files:
    file_refs[f] = guid(f"fileRef_{f}")
for f in asset_catalogs:
    fr = guid(f"fileRef_{f}")
    bf = guid(f"buildFile_{f}")
    file_refs[f] = fr
    build_files[f] = bf

# Entitlements & Info.plist refs
ent_path = f"{SOURCE_DIR}/DigiFox.entitlements"
plist_path = f"{SOURCE_DIR}/Info.plist"
file_refs[ent_path] = guid(f"fileRef_{ent_path}")
file_refs[plist_path] = guid(f"fileRef_{plist_path}")

# Hamlib xcframework
hamlib_path = "Frameworks/Hamlib.xcframework"
file_refs[hamlib_path] = HAMLIB_FW_FILE

# ---------------------------------------------------------------------------
# Build groups from directory structure
# ---------------------------------------------------------------------------

def build_group_tree():
    """Build PBXGroup entries from directory structure."""
    tree = {}
    all_paths = list(file_refs.keys())
    
    for path in all_paths:
        parts = path.split("/")
        for i in range(len(parts) - 1):
            parent = "/".join(parts[:i+1])
            child = "/".join(parts[:i+2])
            if parent not in tree:
                tree[parent] = set()
            tree[parent].add(child)
    
    return tree

dir_tree = build_group_tree()

# Assign GUIDs to directories
dir_guids = {}
for d in dir_tree:
    dir_guids[d] = guid(f"group_{d}")
dir_guids[SOURCE_DIR] = SOURCE_GROUP

# ---------------------------------------------------------------------------
# File type helpers
# ---------------------------------------------------------------------------

def file_type(path):
    if path.endswith(".swift"): return "sourcecode.swift"
    if path.endswith(".m"): return "sourcecode.c.objc"
    if path.endswith(".h"): return "sourcecode.c.h"
    if path.endswith(".c"): return "sourcecode.c.c"
    if path.endswith(".xcassets"): return "folder.assetcatalog"
    if path.endswith(".entitlements"): return "text.plist.entitlements"
    if path.endswith(".plist"): return "text.plist.xml"
    if path.endswith(".xcframework"): return "wrapper.xcframework"
    return "text"

def last_known(path):
    ext_map = {
        ".swift": "sourcecode.swift",
        ".m": "sourcecode.c.objc",
        ".h": "sourcecode.c.h",
        ".c": "sourcecode.c.c",
    }
    for ext, ft in ext_map.items():
        if path.endswith(ext): return ft
    return file_type(path)

# ---------------------------------------------------------------------------
# Generate project.pbxproj
# ---------------------------------------------------------------------------

def generate():
    lines = []
    w = lines.append

    w("// !$*UTF8*$!")
    w("{")
    w("\tarchiveVersion = 1;")
    w("\tclasses = {};")
    w("\tobjectVersion = 56;")
    w("\tobjects = {")
    w("")

    # --- PBXBuildFile ---
    w("/* Begin PBXBuildFile section */")
    for path in sorted(build_files.keys()):
        bf = build_files[path]
        fr = file_refs[path]
        name = os.path.basename(path)
        w(f"\t\t{bf} /* {name} */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};")
    # Hamlib framework build file
    w(f"\t\t{HAMLIB_FW_BUILD} /* Hamlib.xcframework */ = {{isa = PBXBuildFile; fileRef = {HAMLIB_FW_FILE} /* Hamlib.xcframework */; }};")
    w(f"\t\t{HAMLIB_FW_EMBED} /* Hamlib.xcframework */ = {{isa = PBXBuildFile; fileRef = {HAMLIB_FW_FILE} /* Hamlib.xcframework */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};")
    w("/* End PBXBuildFile section */")
    w("")

    # --- PBXCopyFilesBuildPhase (Embed Frameworks) ---
    w("/* Begin PBXCopyFilesBuildPhase section */")
    w(f"\t\t{EMBED_FW_PHASE} /* Embed Frameworks */ = {{")
    w("\t\t\tisa = PBXCopyFilesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tdstPath = \"\";")
    w("\t\t\tdstSubfolderSpec = 10;")
    w(f"\t\t\tfiles = ({HAMLIB_FW_EMBED} /* Hamlib.xcframework */,);")
    w("\t\t\tname = \"Embed Frameworks\";")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXCopyFilesBuildPhase section */")
    w("")

    # --- PBXFileReference ---
    w("/* Begin PBXFileReference section */")
    for path in sorted(file_refs.keys()):
        fr = file_refs[path]
        name = os.path.basename(path)
        ft = last_known(path)
        w(f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ft}; path = \"{name}\"; sourceTree = \"<group>\"; }};")
    # Hamlib xcframework
    w(f"\t\t{HAMLIB_FW_FILE} /* Hamlib.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Hamlib.xcframework; sourceTree = \"<group>\"; }};")
    # App product
    w(f"\t\t{APP_PRODUCT} /* DigiFox.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = DigiFox.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    w("/* End PBXFileReference section */")
    w("")

    # --- PBXFrameworksBuildPhase ---
    w("/* Begin PBXFrameworksBuildPhase section */")
    w(f"\t\t{FRAMEWORKS_PHASE} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w(f"\t\t\tfiles = ({HAMLIB_FW_BUILD} /* Hamlib.xcframework */,);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXFrameworksBuildPhase section */")
    w("")

    # --- PBXGroup ---
    w("/* Begin PBXGroup section */")

    # Main group
    w(f"\t\t{MAIN_GROUP} = {{")
    w("\t\t\tisa = PBXGroup;")
    w("\t\t\tchildren = (")
    w(f"\t\t\t\t{SOURCE_GROUP} /* {SOURCE_DIR} */,")
    w(f"\t\t\t\t{FRAMEWORKS_GROUP} /* Frameworks */,")
    w(f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,")
    w("\t\t\t);")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    # Products group
    w(f"\t\t{PRODUCTS_GROUP} /* Products */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w(f"\t\t\tchildren = ({APP_PRODUCT} /* DigiFox.app */,);")
    w("\t\t\tname = Products;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    # Frameworks group
    w(f"\t\t{FRAMEWORKS_GROUP} /* Frameworks */ = {{")
    w("\t\t\tisa = PBXGroup;")
    w(f"\t\t\tchildren = ({HAMLIB_FW_FILE} /* Hamlib.xcframework */,);")
    w("\t\t\tpath = Frameworks;")
    w("\t\t\tsourceTree = \"<group>\";")
    w("\t\t};")

    # Source groups from directory tree
    def write_group(dir_path):
        g = dir_guids.get(dir_path)
        if not g:
            return
        name = os.path.basename(dir_path)
        children = sorted(dir_tree.get(dir_path, set()))

        w(f"\t\t{g} /* {name} */ = {{")
        w("\t\t\tisa = PBXGroup;")
        w("\t\t\tchildren = (")
        for child in children:
            child_name = os.path.basename(child)
            if child in dir_guids:
                w(f"\t\t\t\t{dir_guids[child]} /* {child_name} */,")
            elif child in file_refs:
                w(f"\t\t\t\t{file_refs[child]} /* {child_name} */,")
        w("\t\t\t);")
        w(f"\t\t\tpath = \"{name}\";")
        w("\t\t\tsourceTree = \"<group>\";")
        w("\t\t};")

    # Write source group and all sub-groups
    all_dirs = sorted(dir_guids.keys())
    for d in all_dirs:
        write_group(d)

    w("/* End PBXGroup section */")
    w("")

    # --- PBXNativeTarget ---
    w("/* Begin PBXNativeTarget section */")
    w(f"\t\t{NATIVE_TARGET} /* DigiFox */ = {{")
    w("\t\t\tisa = PBXNativeTarget;")
    w(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_TGT};")
    w("\t\t\tbuildPhases = (")
    w(f"\t\t\t\t{SOURCES_PHASE} /* Sources */,")
    w(f"\t\t\t\t{FRAMEWORKS_PHASE} /* Frameworks */,")
    w(f"\t\t\t\t{RESOURCES_PHASE} /* Resources */,")
    w(f"\t\t\t\t{EMBED_FW_PHASE} /* Embed Frameworks */,")
    w("\t\t\t);")
    w("\t\t\tbuildRules = ();")
    w("\t\t\tdependencies = ();")
    w("\t\t\tname = DigiFox;")
    w(f"\t\t\tproductName = DigiFox;")
    w(f"\t\t\tproductReference = {APP_PRODUCT} /* DigiFox.app */;")
    w("\t\t\tproductType = \"com.apple.product-type.application\";")
    w("\t\t};")
    w("/* End PBXNativeTarget section */")
    w("")

    # --- PBXProject ---
    w("/* Begin PBXProject section */")
    w(f"\t\t{PROJECT_GUID} /* Project object */ = {{")
    w("\t\t\tisa = PBXProject;")
    w(f"\t\t\tbuildConfigurationList = {CONFIG_LIST_PROJ};")
    w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    w("\t\t\tdevelopmentRegion = de;")
    w("\t\t\thasScannedForEncodings = 0;")
    w("\t\t\tknownRegions = (de, Base);")
    w(f"\t\t\tmainGroup = {MAIN_GROUP};")
    w(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
    w("\t\t\tprojectDirPath = \"\";")
    w("\t\t\tprojectRoot = \"\";")
    w(f"\t\t\ttargets = ({NATIVE_TARGET} /* DigiFox */,);")
    w("\t\t};")
    w("/* End PBXProject section */")
    w("")

    # --- PBXResourcesBuildPhase ---
    w("/* Begin PBXResourcesBuildPhase section */")
    w(f"\t\t{RESOURCES_PHASE} /* Resources */ = {{")
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for ac in sorted(asset_catalogs):
        w(f"\t\t\t\t{build_files[ac]} /* {os.path.basename(ac)} */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXResourcesBuildPhase section */")
    w("")

    # --- PBXSourcesBuildPhase ---
    w("/* Begin PBXSourcesBuildPhase section */")
    w(f"\t\t{SOURCES_PHASE} /* Sources */ = {{")
    w("\t\t\tisa = PBXSourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    for sf in sorted(all_source_files):
        w(f"\t\t\t\t{build_files[sf]} /* {os.path.basename(sf)} */,")
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
    w("/* End PBXSourcesBuildPhase section */")
    w("")

    # --- XCBuildConfiguration ---
    common_settings = f"""
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASCL_COMPILER_FLAGS = "";
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_VERSION = 5.0;"""

    target_settings = f"""
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_ENTITLEMENTS = "DigiFox/DigiFox.entitlements";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tDEVELOPMENT_TEAM = "{TEAM_ID}";
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = "DigiFox/Info.plist";
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "{BRIDGING_HEADER}";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t\tHEADER_SEARCH_PATHS = ("$(PROJECT_DIR)/vendor/hamlib/include", "$(PROJECT_DIR)/Frameworks/Hamlib.xcframework/ios-arm64/Hamlib.framework/Headers");
\t\t\t\tLIBRARY_SEARCH_PATHS = "$(PROJECT_DIR)/vendor/hamlib/lib";
\t\t\t\tOTHER_LDFLAGS = ("-lhamlib",);
\t\t\t\tEXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64;"""

    w("/* Begin XCBuildConfiguration section */")
    # Project Debug
    w(f"\t\t{CONFIG_DEBUG_P} /* Debug */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(common_settings)
    w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    w("\t\t\t\tENABLE_TESTABILITY = YES;")
    w("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
    w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
    w("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\"DEBUG=1\", \"$(inherited)\");")
    w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited) DEBUG\";")
    w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
    w("\t\t\t};")
    w("\t\t\tname = Debug;")
    w("\t\t};")
    # Project Release
    w(f"\t\t{CONFIG_RELEASE_P} /* Release */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(common_settings)
    w("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
    w("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    w("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";")
    w("\t\t\t\tVALIDATE_PRODUCT = YES;")
    w("\t\t\t};")
    w("\t\t\tname = Release;")
    w("\t\t};")
    # Target Debug
    w(f"\t\t{CONFIG_DEBUG_T} /* Debug */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(target_settings)
    w("\t\t\t};")
    w("\t\t\tname = Debug;")
    w("\t\t};")
    # Target Release
    w(f"\t\t{CONFIG_RELEASE_T} /* Release */ = {{")
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(target_settings)
    w("\t\t\t};")
    w("\t\t\tname = Release;")
    w("\t\t};")
    w("/* End XCBuildConfiguration section */")
    w("")

    # --- XCConfigurationList ---
    w("/* Begin XCConfigurationList section */")
    w(f"\t\t{CONFIG_LIST_PROJ} /* Build configuration list for PBXProject */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w(f"\t\t\tbuildConfigurations = ({CONFIG_DEBUG_P} /* Debug */, {CONFIG_RELEASE_P} /* Release */,);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w(f"\t\t{CONFIG_LIST_TGT} /* Build configuration list for PBXNativeTarget */ = {{")
    w("\t\t\tisa = XCConfigurationList;")
    w(f"\t\t\tbuildConfigurations = ({CONFIG_DEBUG_T} /* Debug */, {CONFIG_RELEASE_T} /* Release */,);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
    w("/* End XCConfigurationList section */")
    w("")

    w("\t};")
    w(f"\trootObject = {PROJECT_GUID} /* Project object */;")
    w("}")

    return "\n".join(lines)

# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

os.makedirs("DigiFox.xcodeproj", exist_ok=True)
content = generate()
outpath = "DigiFox.xcodeproj/project.pbxproj"
with open(outpath, "w") as f:
    f.write(content)

print(f"Generated {outpath}")
print(f"  Swift files:   {len(swift_files)}")
print(f"  ObjC files:    {len(objc_m_files)}")
print(f"  C files:       {len(c_files)}")
print(f"  Headers:       {len(objc_h_files)}")
print(f"  Asset catalogs: {len(asset_catalogs)}")
print(f"  Total sources: {len(all_source_files)}")
