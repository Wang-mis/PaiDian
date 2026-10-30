#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; rerun after adding source files."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
# Application identity must survive a brand/target rename and project regeneration.
legacy_bundle_ids = {
    'PaiDian': 'org.anylisten.AnyListen',
    'PaiDianTests': 'org.anylisten.AnyListenTests',
    'PaiDianUITests': 'org.anylisten.AnyListenUITests',
}
identity_keys = {'PRODUCT_BUNDLE_IDENTIFIER', 'DEVELOPMENT_TEAM', 'CODE_SIGN_STYLE',
                 'CODE_SIGN_IDENTITY', 'PROVISIONING_PROFILE', 'PROVISIONING_PROFILE_SPECIFIER'}
saved_identity = {}
existing_project = root / 'PaiDian.xcodeproj' / 'project.pbxproj'
if existing_project.exists():
    project_data = json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(existing_project)], text=True))
    old_objects = project_data['objects']
    for target in old_objects.values():
        if target.get('isa') != 'PBXNativeTarget': continue
        # Also accepts the pre-rename targets during the first regeneration.
        target_name = target['name'].replace('AnyListen', 'PaiDian')
        for config_id in old_objects[target['buildConfigurationList']]['buildConfigurations']:
            config = old_objects[config_id]
            saved_identity[target_name, config['name']] = {
                key: value for key, value in config['buildSettings'].items() if key in identity_keys}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def quote(text): return json.dumps(str(text), ensure_ascii=False)
objects = {}
def obj(name, body):
    key = uid(name); objects[key] = body; return key
def arr(values): return '(' + ','.join(values) + (',' if values else '') + ')'
products = []
targets = []
target_ids = {name: uid('target:' + name) for name in ['PaiDian', 'PaiDianTests', 'PaiDianUITests']}
groups = []
for name in target_ids:
    files = sorted((root / name).rglob('*.swift'))
    refs, builds = [], []
    for file in files:
        path = file.relative_to(root)
        ref = obj('file:' + str(path), '{isa=PBXFileReference;lastKnownFileType=sourcecode.swift;path=' + quote(path) + ';sourceTree=SOURCE_ROOT;}')
        refs.append(ref)
        builds.append(obj('build:' + str(path), '{isa=PBXBuildFile;fileRef=' + ref + ';}'))
    group = obj('group:' + name, '{isa=PBXGroup;name=' + name + ';children=' + arr(refs) + ';sourceTree="<group>";}'); groups.append(group)
    sources = obj('sources:' + name, '{isa=PBXSourcesBuildPhase;buildActionMask=2147483647;files=' + arr(builds) + ';runOnlyForDeploymentPostprocessing=0;}')
    frameworks = obj('frameworks:' + name, '{isa=PBXFrameworksBuildPhase;buildActionMask=2147483647;files=();runOnlyForDeploymentPostprocessing=0;}')
    resource_builds = []
    if name == 'PaiDian':
        asset = obj('asset', '{isa=PBXFileReference;lastKnownFileType=folder.assetcatalog;path="PaiDian/Assets.xcassets";sourceTree=SOURCE_ROOT;}')
        refs.append(asset)
        objects[group] = '{isa=PBXGroup;name=' + name + ';children=' + arr(refs) + ';sourceTree="<group>";}'
        resource_builds.append(obj('assetbuild','{isa=PBXBuildFile;fileRef='+asset+';}'))
        bundled = obj('bundledsources', '{isa=PBXFileReference;lastKnownFileType=folder;path="PaiDian/BundledSources";sourceTree=SOURCE_ROOT;}')
        refs.append(bundled)
        objects[group] = '{isa=PBXGroup;name=' + name + ';children=' + arr(refs) + ';sourceTree="<group>";}'
        resource_builds.append(obj('bundledsourcesbuild','{isa=PBXBuildFile;fileRef='+bundled+';}'))
        legal = obj('legal', '{isa=PBXFileReference;lastKnownFileType=folder;path="PaiDian/Legal";sourceTree=SOURCE_ROOT;}')
        refs.append(legal)
        objects[group] = '{isa=PBXGroup;name=' + name + ';children=' + arr(refs) + ';sourceTree="<group>";}'
        resource_builds.append(obj('legalbuild','{isa=PBXBuildFile;fileRef='+legal+';}'))
    elif name == 'PaiDianTests':
        for fixture in sorted((root / name / 'Fixtures').glob('*')):
            if fixture.suffix not in ('.flac', '.m4a'): continue
            path = fixture.relative_to(root)
            ref = obj('fixture:' + str(path), '{isa=PBXFileReference;lastKnownFileType=file;path=' + quote(path) + ';sourceTree=SOURCE_ROOT;}')
            refs.append(ref)
            resource_builds.append(obj('fixturebuild:' + str(path), '{isa=PBXBuildFile;fileRef=' + ref + ';}'))
        objects[group] = '{isa=PBXGroup;name=' + name + ';children=' + arr(refs) + ';sourceTree="<group>";}'
    resources = obj('resources:' + name, '{isa=PBXResourcesBuildPhase;buildActionMask=2147483647;files='+arr(resource_builds)+';runOnlyForDeploymentPostprocessing=0;}')
    is_app = name == 'PaiDian'; is_ui = name.endswith('UITests')
    ext = '.app' if is_app else '.xctest'
    product = obj('product:' + name, '{isa=PBXFileReference;explicitFileType=' + ('wrapper.application' if is_app else 'wrapper.cfbundle') + ';includeInIndex=0;path=' + name + ext + ';sourceTree=BUILT_PRODUCTS_DIR;}'); products.append(product)
    configs = []
    for configuration in ['Debug', 'Release']:
        settings = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': legacy_bundle_ids[name], 'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'targeted', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','GENERATE_INFOPLIST_FILE':'NO' if is_app else 'YES', 'CURRENT_PROJECT_VERSION':'1', 'MARKETING_VERSION':'1.0.0', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
        settings.update(saved_identity.get((name, configuration), {}))
        if is_app: settings.update({'INFOPLIST_FILE':'PaiDian/Info.plist','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon'})
        elif is_ui: settings['TEST_TARGET_NAME'] = 'PaiDian'
        else: settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/PaiDian.app/PaiDian','BUNDLE_LOADER':'$(TEST_HOST)'})
        settings.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if configuration=='Debug' else '-O','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if configuration=='Debug' else '', 'DEBUG_INFORMATION_FORMAT':'dwarf' if configuration=='Debug' else 'dwarf-with-dsym'})
        configs.append(obj('config:' + name + configuration,'{isa=XCBuildConfiguration;name=' + configuration + ';buildSettings={' + ''.join(k+'='+quote(v)+';' for k,v in settings.items()) + '};}'))
    config_list = obj('configs:' + name,'{isa=XCConfigurationList;buildConfigurations='+arr(configs)+';defaultConfigurationIsVisible=0;defaultConfigurationName=Release;}')
    deps = []
    if not is_app:
        proxy = obj('proxy:'+name,'{isa=PBXContainerItemProxy;containerPortal='+uid('project')+';proxyType=1;remoteGlobalIDString='+target_ids['PaiDian']+';remoteInfo=PaiDian;}')
        deps.append(obj('dep:'+name,'{isa=PBXTargetDependency;target='+target_ids['PaiDian']+';targetProxy='+proxy+';}'))
    product_type = 'com.apple.product-type.application' if is_app else ('com.apple.product-type.bundle.ui-testing' if is_ui else 'com.apple.product-type.bundle.unit-test')
    target = obj('target:'+name,'{isa=PBXNativeTarget;buildConfigurationList='+config_list+';buildPhases='+arr([sources,frameworks,resources])+';buildRules=();dependencies='+arr(deps)+';name='+name+';productName='+name+';productReference='+product+';productType='+quote(product_type)+';}'); targets.append(target)
pg = obj('products','{isa=PBXGroup;children='+arr(products)+';name=Products;sourceTree="<group>";}')
main = obj('main','{isa=PBXGroup;children='+arr(groups+[pg])+';sourceTree="<group>";}')
configs = []
for config in ['Debug','Release']:
    configs.append(obj('projectconfig:'+config,'{isa=XCBuildConfiguration;name='+config+';buildSettings={CLANG_ENABLE_MODULES=YES;CLANG_ENABLE_OBJC_ARC=YES;ENABLE_TESTABILITY='+('YES' if config=='Debug' else 'NO')+';SWIFT_COMPILATION_MODE='+('singlefile' if config=='Debug' else 'wholemodule')+';};}'))
cl = obj('projectconfigs','{isa=XCConfigurationList;buildConfigurations='+arr(configs)+';defaultConfigurationIsVisible=0;defaultConfigurationName=Release;}')
project = obj('project','{isa=PBXProject;attributes={BuildIndependentTargetsInParallel=YES;LastUpgradeCheck=2700;};buildConfigurationList='+cl+';compatibilityVersion="Xcode 14.0";developmentRegion=zh_CN;hasScannedForEncodings=0;knownRegions=(zh_CN,en,Base,);mainGroup='+main+';productRefGroup='+pg+';projectDirPath="";projectRoot="";targets='+arr(targets)+';}')
directory = root / 'PaiDian.xcodeproj'; directory.mkdir(exist_ok=True)
(directory/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion=1;classes={};objectVersion=56;objects={\n'+ '\n'.join(k+'='+v+';' for k,v in objects.items())+'\n};rootObject='+project+';}\n')
schemes = directory/'xcshareddata'/'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def ref(name): return '<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'+target_ids[name]+'" BuildableName="'+name+('.app' if name=='PaiDian' else '.xctest')+'" BlueprintName="'+name+'" ReferencedContainer="container:PaiDian.xcodeproj"/>'
(schemes/'PaiDian.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+ref('PaiDian')+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>'+''.join('<TestableReference skipped="NO">'+ref(t)+'</TestableReference>' for t in ['PaiDianTests','PaiDianUITests'])+'</Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+ref('PaiDian')+'</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+ref('PaiDian')+'</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>')
live_scheme = (schemes/'PaiDian.xcscheme').read_text().replace('shouldUseLaunchSchemeArgsEnv="YES"', 'shouldUseLaunchSchemeArgsEnv="NO"')
live_scheme = live_scheme.replace('<Testables>', '<EnvironmentVariables><EnvironmentVariable key="PAIDIAN_LIVE_SOURCE_VALIDATION" value="1" isEnabled="YES"/></EnvironmentVariables><Testables>')
live_scheme = live_scheme.replace('<TestableReference skipped="NO">'+ref('PaiDianUITests')+'</TestableReference>', '')
(schemes/'LiveSources.xcscheme').write_text(live_scheme)
import_scheme=live_scheme.replace('<EnvironmentVariables>','<EnvironmentVariables><EnvironmentVariable key="PAIDIAN_IMPORT_SOURCES" value="1" isEnabled="YES"/>')
(schemes/'ImportSources.xcscheme').write_text(import_scheme)
screenshot_scheme = (schemes/'PaiDian.xcscheme').read_text().replace('shouldUseLaunchSchemeArgsEnv="YES"', 'shouldUseLaunchSchemeArgsEnv="NO"')
screenshot_scheme = screenshot_scheme.replace('<Testables>', '<EnvironmentVariables><EnvironmentVariable key="PAIDIAN_RELEASE_SCREENSHOTS" value="1" isEnabled="YES"/></EnvironmentVariables><Testables>')
(schemes/'Screenshots.xcscheme').write_text(screenshot_scheme)
print('Generated PaiDian.xcodeproj')
