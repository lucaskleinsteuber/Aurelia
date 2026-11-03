#!/bin/zsh
# Real sandboxed caller -> GUI helper -> independent worker -> signed synthetic DMG
# replacement -> automatic relaunch. No windows, personal app/data, network or media.
set -euo pipefail
repository_root=${0:A:h:h}
source "$repository_root/scripts/workspace-paths.sh"
/bin/sh "$repository_root/scripts/prune-workspace.sh" || true
python3 - "$repository_root" "$other_root" <<'PY'
import datetime,json,os,pathlib,plistlib,re,shutil,subprocess,sys,time,uuid
repository=pathlib.Path(sys.argv[1]);artifacts=pathlib.Path(sys.argv[2])
root=pathlib.Path.home()/'Library/Caches/Aurelia/TestRuns'/('update-worker-'+str(uuid.uuid4()))
root.mkdir(parents=True)
def run(args,**kw):
    try:return subprocess.run([str(a) for a in args],check=True,**kw)
    except subprocess.CalledProcessError as error:
        if error.stderr:print(error.stderr.decode() if isinstance(error.stderr,bytes) else error.stderr,file=sys.stderr)
        raise
def wait_for(predicate,seconds=25):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for the synthetic worker')
def plist(bundle,identifier,build,executable):
    (bundle/'Contents/MacOS').mkdir(parents=True)
    with (bundle/'Contents/Info.plist').open('wb') as f:
        plistlib.dump(dict(CFBundleExecutable=executable,CFBundleIdentifier=identifier,CFBundleName='Aurelia Update Fixture',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.1' if build==101 else '0.1.0',CFBundleVersion=str(build),LSUIElement=True),f)
def sign(bundle,entitlements=None):
    args=['/usr/bin/codesign','--force','--sign',identity,'--timestamp=none']
    if entitlements:args+=['--entitlements',entitlements]
    run(args+[bundle],capture_output=True)
try:
    installed=pathlib.Path('/Applications/Aurelia.app')
    details=subprocess.run(['/usr/bin/codesign','-dv','--verbose=2',str(installed)],capture_output=True,text=True,check=True).stderr
    authority=next(s.removeprefix('Authority=') for s in details.splitlines() if s.startswith('Authority=Apple Development:'))
    identities=subprocess.check_output(['/usr/bin/security','find-identity','-v','-p','codesigning'],text=True)
    identity=next(match[1] for line in identities.splitlines() if (match:=re.search(r'([A-F0-9]{40}) "([^"]+)"',line)) and match[2]==authority)
    identifier='com.lucas.aurelia.updatefixture.'+str(uuid.uuid4())
    app=root/'Aurelia.app';candidate=root/'Image/Aurelia.app';helper=app/'Contents/Helpers/Fixture Helper.app'
    plist(app,identifier,100,'Fixture');plist(candidate,identifier,101,'Fixture');plist(helper,identifier+'.helper',100,'Worker')
    shared=root/'Shared/Updates';shared.mkdir(parents=True)
    with (root/'sandbox.plist').open('wb') as f:
        plistlib.dump({'com.apple.security.app-sandbox':True,'com.apple.security.temporary-exception.files.absolute-path.read-write':[str(root)+'/']},f)
    quote=lambda x:json.dumps(str(x))
    (root/'Fixture.swift').write_text('''import AppKit
import Foundation
@main @MainActor final class Fixture: NSObject, NSApplicationDelegate {
 let termination = ApplicationTerminationCoordinator()
 static func main() {
  let app = NSApplication.shared; let delegate = Fixture()
  app.delegate = delegate; app.setActivationPolicy(.prohibited); app.run()
 }
 func applicationDidFinishLaunching(_ notification: Notification) {
  let root = URL(fileURLWithPath: ROOT)
  if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "101" {
   try! JSONSerialization.data(withJSONObject: ["build": 101, "windows": NSApplication.shared.windows.count]).write(to: root.appendingPathComponent("relaunch.json"))
   Task { @MainActor in
    let label = try! String(contentsOf: root.appendingPathComponent("job.txt"), encoding: .utf8)
    for _ in 0..<100 {
     let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/bin/launchctl")
     probe.arguments = ["list", label]; probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
     do { try probe.run() } catch { exit(6) }
     probe.waitUntilExit()
     if probe.terminationStatus != 0 {
      try! Data("still running after installer cleanup".utf8).write(to: root.appendingPathComponent("relaunch-survived.txt"))
      NSApplication.shared.terminate(nil); return
     }
     try? await Task.sleep(for: .milliseconds(50))
    }
    exit(7)
   }
   return
  }
  Task { @MainActor in
   do {
    let updates = root.appendingPathComponent("Shared/Updates")
    let directory = updates.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let image = directory.appendingPathComponent("Aurelia-0.1.1-101-macOS-arm64.dmg")
    try FileManager.default.copyItem(at: root.appendingPathComponent("template.dmg"), to: image)
    let request = try MacUpdateInstallRequest.prepare(image: image, build: 101, appPID: getpid(), root: updates)
    try request.save(in: updates)
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false; configuration.createsNewApplicationInstance = true
    _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Fixture Helper.app"), configuration: configuration)
    try await request.waitForAcknowledgement(in: updates)
    NSApplication.shared.terminate(nil)
   } catch { try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("sender-error.txt")); exit(2) }
  }
 }
 func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
  termination.request(shutdown: { await Task.yield() }, terminate: { sender.terminate(nil) })
 }
}
'''.replace('ROOT',quote(root)))
    (root/'Worker.swift').write_text('''import AppKit
import Foundation
@main @MainActor final class Worker: NSObject, NSApplicationDelegate {
 static func main() {
  let root = URL(fileURLWithPath: ROOT)
  if UpdateWorkerLaunch.runIfRequested(CommandLine.arguments, work: {
   try! Data(CommandLine.arguments[2].utf8).write(to: root.appendingPathComponent("job.txt"))
   let updates = root.appendingPathComponent("Shared/Updates")
   if (try? String(contentsOf: root.appendingPathComponent("mode.txt"), encoding: .utf8)) == "lifetime" {
    let request = try! MacUpdateInstallRequest.claim(in: updates)!
    try! request.writeStatus("accepted", in: updates)
    Thread.sleep(forTimeInterval: 5)
    guard kill(request.appPID, 0) != 0 else { exit(4) }
    try! Data("survived".utf8).write(to: root.appendingPathComponent("survived.txt"))
    UpdateInstallation.removeDownloadedImage(at: try! request.image(in: updates))
   } else {
    _ = UpdateInstaller.runPending(app: root.appendingPathComponent("Aurelia.app"), root: updates, presentsFailure: false)
   }
  }) { return }
  let app = NSApplication.shared; let delegate = Worker()
  app.delegate = delegate; app.setActivationPolicy(.prohibited); app.run()
 }
 func applicationDidFinishLaunching(_ notification: Notification) {
  Task { @MainActor in
   do { try UpdateWorkerLaunch.submit(executable: Bundle.main.executableURL!) }
   catch { exit(5) }
   NSApplication.shared.terminate(nil)
  }
 }
}
'''.replace('ROOT',quote(root)))
    common=[repository/'clients/macos/UpdateHandoff/MacUpdateInstallRequest.swift']
    run(['xcrun','swiftc','-warnings-as-errors','-swift-version','6',*common,repository/'clients/macos/Aurelia/ApplicationTerminationCoordinator.swift',root/'Fixture.swift','-o',app/'Contents/MacOS/Fixture'])
    shutil.copy2(app/'Contents/MacOS/Fixture',candidate/'Contents/MacOS/Fixture')
    run(['xcrun','swiftc','-warnings-as-errors','-swift-version','6',*common,*[repository/('clients/macos/AureliaServerHost/'+n+'.swift') for n in ('UpdateWorkerLaunch','UpdateInstaller','UpdateInstallation')],root/'Worker.swift','-o',helper/'Contents/MacOS/Worker'])
    sign(helper);sign(app,root/'sandbox.plist');sign(candidate)
    run(['/usr/bin/hdiutil','create','-quiet','-fs','HFS+','-format','UDZO','-volname','Aurelia Update Fixture','-srcfolder',root/'Image',root/'template.dmg'])
    receipts=[]
    for mode in ('lifetime','install'):
        (root/'mode.txt').write_text(mode)
        run(['/usr/bin/open','-W','-n',app],timeout=15)
        if mode=='lifetime':
            wait_for(lambda:(root/'survived.txt').exists())
            print('PASS: the independent production worker survived the sandboxed app and GUI helper exiting.',flush=True)
        else:
            wait_for(lambda:(root/'relaunch.json').exists())
            result=json.loads((root/'relaunch.json').read_text())
            status=json.loads((shared/'InstallStatus.json').read_text())
            assert result=={'build':101,'windows':0} and status['phase']=='installed'
            assert plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']=='101'
            assert not list(root.glob('.aurelia-update-*')) and not (shared/'PendingInstall.json').exists()
            run(['/usr/bin/codesign','--verify','--deep','--strict',app],capture_output=True)
            print('PASS: production request, app quit, signed DMG, signature/team/build checks, bundle replacement and automatic relaunch completed; no windows or media.',flush=True)
        label=(root/'job.txt').read_text()
        wait_for(lambda:subprocess.run(['/bin/launchctl','list',label],capture_output=True).returncode!=0)
        if mode=='install':
            wait_for(lambda:(root/'relaunch-survived.txt').exists())
            print('PASS: the automatically relaunched app remained alive after its installer job was removed.',flush=True)
        receipts.append({'scenario':mode,'passed':True,'transientJobRemoved':True})
    proof=artifacts/'Logs'/('update-worker-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'.json')
    proof.write_text(json.dumps(receipts,indent=2)+'\n')
finally:
    if (root/'job.txt').exists():
        label=(root/'job.txt').read_text()
        if label.startswith('com.lucas.aurelia.media.update.'):
            subprocess.run(['/bin/launchctl','remove',label],capture_output=True)
    shutil.rmtree(root,ignore_errors=True)
PY
