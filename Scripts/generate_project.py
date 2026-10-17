#!/usr/bin/env python3
"""Deterministic dependency-free Xcode project generator; project is already included."""
from pathlib import Path
import hashlib, plistlib
ROOT = Path(__file__).resolve().parent.parent

def ident(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def q(value):
    value = str(value)
    return '"' + value.replace('\\','\\\\').replace('"','\\"') + '"'
objects = {}
def add(key, text):
    identifier = ident(key); objects[identifier] = text; return identifier

def listing(items): return '(' + ', '.join(items) + (',' if items else '') + ')'
configs = ['Debug', 'Release', 'SharedDebug', 'SharedRelease']
shared = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT/'Shared').glob('*.swift'))
app = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT/'AudioTrace').glob('*.swift'))
extension = ['BroadcastExtension/SampleHandler.swift']
refs = {}
for path in shared + app + extension + ['Configuration/App-Info.plist','Configuration/Native-Info.plist','Configuration/Extension-Info.plist','Configuration/Shared.entitlements','Configuration/Personal.entitlements','Configuration/Identifiers.xcconfig','Configuration/PrivacyInfo.xcprivacy','AudioTrace/Assets.xcassets','README.md','TEST_PLAN.md','KNOWN_LIMITATIONS.md']:
    typ = 'sourcecode.swift' if path.endswith('.swift') else ('folder.assetcatalog' if path.endswith('.xcassets') else 'text')
    refs[path] = add('ref:'+path, '{isa = PBXFileReference; lastKnownFileType = '+q(typ)+'; path = '+q(path)+'; sourceTree = "<group>";}')
appProduct = add('product:app','{isa = PBXFileReference; explicitFileType = wrapper.application; path = AudioTrace.app; sourceTree = BUILT_PRODUCTS_DIR;}')
extProduct = add('product:extension','{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = AudioTraceBroadcast.appex; sourceTree = BUILT_PRODUCTS_DIR;}')
products = add('products','{isa = PBXGroup; name = Products; children = '+listing([appProduct,extProduct])+'; sourceTree = "<group>";}')
main = add('main','{isa = PBXGroup; children = '+listing(list(refs.values())+[products])+'; sourceTree = "<group>";}')
appTarget = ident('target:app'); extTarget = ident('target:extension'); project = ident('project')
proxy = add('proxy','{isa = PBXContainerItemProxy; containerPortal = '+project+'; proxyType = 1; remoteGlobalIDString = '+extTarget+'; remoteInfo = AudioTraceBroadcast;}')
dep = add('dependency','{isa = PBXTargetDependency; target = '+extTarget+'; targetProxy = '+proxy+';}')
embedFile = add('embedfile','{isa = PBXBuildFile; fileRef = '+extProduct+'; settings = {ATTRIBUTES = (RemoveHeadersOnCopy,);};}')
embed = add('embed','{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ('+embedFile+',); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;}')

def config_list(owner, target=False, ext=False):
    ids=[]
    for config in configs:
        isShared = config.startswith('Shared'); debug = config.endswith('Debug')
        settings = {}
        if not target:
            settings = dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='17.0', SWIFT_VERSION='5.0', CLANG_ENABLE_MODULES='YES', SWIFT_STRICT_CONCURRENCY='minimal', ENABLE_USER_SCRIPT_SANDBOXING='YES', DEBUG_INFORMATION_FORMAT='dwarf' if debug else 'dwarf-with-dsym', SWIFT_OPTIMIZATION_LEVEL='-Onone' if debug else '-O', SWIFT_COMPILATION_MODE='singlefile' if debug else 'wholemodule', CLANG_WARN_DOCUMENTATION_COMMENTS='YES', GCC_C_LANGUAGE_STANDARD='gnu17', GCC_WARN_64_TO_32_BIT_CONVERSION='YES', GCC_WARN_UNDECLARED_SELECTOR='YES', GCC_WARN_UNINITIALIZED_AUTOS='YES_AGGRESSIVE', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if debug else '')
        else:
            settings = dict(PRODUCT_NAME='AudioTraceBroadcast' if ext else 'AudioTrace', PRODUCT_BUNDLE_IDENTIFIER='$(AUDIOTRACE_BUNDLE_ID).Broadcast' if ext else '$(AUDIOTRACE_BUNDLE_ID)', CODE_SIGN_STYLE='Automatic', DEVELOPMENT_TEAM='$(AUDIOTRACE_TEAM)', CODE_SIGN_ENTITLEMENTS='Configuration/Shared.entitlements' if isShared else 'Configuration/Personal.entitlements', INFOPLIST_FILE='Configuration/Extension-Info.plist' if ext else 'Configuration/App-Info.plist', GENERATE_INFOPLIST_FILE='NO', TARGETED_DEVICE_FAMILY='1,2', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', MARKETING_VERSION='1.1', CURRENT_PROJECT_VERSION='3', AUDIOTRACE_SHARED_CAPTURE='YES' if isShared else 'NO', LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks'+(' @executable_path/../../Frameworks' if ext else ''), ENABLE_APP_INTENTS_METADATA_GENERATION='NO')
            if ext: settings.update(APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES')
            else:
                settings.update(ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
                for sdk in ['iphoneos', 'iphonesimulator']:
                    for major in [27, 28, 29]:
                        settings[f'INFOPLIST_FILE[sdk={sdk}{major}*]'] = 'Configuration/Native-Info.plist'
        body = ' '.join(q(k)+' = '+q(v)+';' for k,v in settings.items())
        base = 'baseConfigurationReference = '+refs['Configuration/Identifiers.xcconfig']+';' if target else ''
        ids.append(add(owner+':config:'+config, '{isa = XCBuildConfiguration; '+base+' buildSettings = {'+body+'}; name = '+q(config)+';}'))
    return add(owner+':configlist','{isa = XCConfigurationList; buildConfigurations = '+listing(ids)+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;}')

for name, sources, tid, product, ext in [('app',shared+app,appTarget,appProduct,False), ('extension',shared+extension,extTarget,extProduct,True)]:
    builds = [add('build:'+name+':'+path,'{isa = PBXBuildFile; fileRef = '+refs[path]+';}') for path in sources]
    phase = add('sources:'+name,'{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+listing(builds)+'; runOnlyForDeploymentPostprocessing = 0;}')
    frameworks = add('frameworks:'+name,'{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;}')
    resourcePaths = ['Configuration/PrivacyInfo.xcprivacy'] + ([] if ext else ['AudioTrace/Assets.xcassets'])
    resourceBuilds = [add('resource:'+name+':'+path, '{isa = PBXBuildFile; fileRef = '+refs[path]+';}') for path in resourcePaths]
    resources = add('resources:'+name,'{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = '+listing(resourceBuilds)+'; runOnlyForDeploymentPostprocessing = 0;}')
    phases = [phase,frameworks,resources]+([] if ext else [embed])
    objects[tid] = '{isa = PBXNativeTarget; buildConfigurationList = '+config_list(name,True,ext)+'; buildPhases = '+listing(phases)+'; buildRules = (); dependencies = '+listing([] if ext else [dep])+'; name = '+('AudioTraceBroadcast' if ext else 'AudioTrace')+'; productName = '+('AudioTraceBroadcast' if ext else 'AudioTrace')+'; productReference = '+product+'; productType = '+q('com.apple.product-type.app-extension' if ext else 'com.apple.product-type.application')+';}'
objects[project] = '{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2620; LastUpgradeCheck = 2620; TargetAttributes = {'+appTarget+' = {CreatedOnToolsVersion = 26.2; ProvisioningStyle = Automatic;}; '+extTarget+' = {CreatedOnToolsVersion = 26.2; ProvisioningStyle = Automatic;};};}; buildConfigurationList = '+config_list('project')+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = '+main+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = '+listing([appTarget,extTarget])+';}'
projectDir = ROOT/'AudioTrace.xcodeproj'; projectDir.mkdir(exist_ok=True)
(projectDir/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
for name,debug,release in [('AudioTrace','SharedDebug','SharedRelease'),('AudioTrace-SharedCapture','SharedDebug','SharedRelease'),('AudioTrace-AppOnly','Debug','Release')]:
    schemes = projectDir/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
    ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{appTarget}" BuildableName="AudioTrace.app" BlueprintName="AudioTrace" ReferencedContainer="container:AudioTrace.xcodeproj"/>'
    (schemes/(name+'.xcscheme')).write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2620" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="{debug}" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="{debug}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="{release}" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="{debug}"/><ArchiveAction buildConfiguration="{release}" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated AudioTrace.xcodeproj; default AudioTrace scheme includes broadcast capture')
