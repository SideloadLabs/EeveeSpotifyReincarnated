import UIKit
import SwiftUI

private final class ReusingSettingsTable: UITableView {
 var recycled: UITableViewCell?
 override func dequeueReusableCell(withIdentifier identifier: String) -> UITableViewCell? {
  recycled ?? super.dequeueReusableCell(withIdentifier:identifier)
 }
}

private struct LabelRow: View {
 let title: String
 let subtitle: String?
 let icon: String
 let color: Color
 var body: some View {
  HStack(spacing:14) {
   Image(systemName:icon).font(.system(size:15,weight:.semibold)).foregroundStyle(.white)
    .frame(width:30,height:30).background(RoundedRectangle(cornerRadius:8).fill(color))
   VStack(alignment:.leading,spacing:2){Text(title).foregroundStyle(.primary);if let subtitle{Text(subtitle).font(.footnote).foregroundStyle(.secondary)}}
   Spacer(minLength:8)
  }.padding(.vertical,2)
 }
}
private struct SettingsRoot: View {
 @State var logging=false
 var body: some View {
  List {
   Section {Text("Developer’s Note...").foregroundStyle(.green)}
   Section {LabelRow(title:"Поддержать проект",subtitle:"Ваш вклад помогает обновлять этот твик и…",icon:"cup.and.saucer.fill",color:.red)}
   Section(header:Text("Устранение неполадок"),footer:Text("Включите ведение журнала, затем экспортируйте или очистите журнал.")) {
    Toggle("Журнал отладки",isOn:$logging)
    LabelRow(title:"Export Debug Log",subtitle:nil,icon:"square.and.arrow.up",color:.blue)
    LabelRow(title:"Clear Debug Log",subtitle:nil,icon:"trash.fill",color:.gray)
   }
   Section(header:Text("Сброс"),footer:Text("Оба действия закроют приложение по завершении.")) {
    LabelRow(title:"Очистить данные",subtitle:"Очищает кэши",icon:"arrow.counterclockwise",color:.orange)
    LabelRow(title:"Full Reset",subtitle:"Стирает всё и выполняет выход из аккаунта",icon:"exclamationmark.triangle.fill",color:.red)
   }
   Spacer().frame(height:40).listRowBackground(Color.clear).listRowSeparator(.hidden)
  }.listStyle(.insetGrouped).tint(.green).preferredColorScheme(.dark)
 }
}
@objc(SAPFixtureEeveeSettingsViewController)
class FixtureSettings: UIViewController {
 override func viewDidLoad(){
  super.viewDidLoad();title="EeveeSpotify"
  let child=UIHostingController(rootView:AnyView(SettingsRoot()));addChild(child)
  child.view.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(child.view);child.didMove(toParent:self)
  NSLayoutConstraint.activate([child.view.topAnchor.constraint(equalTo:view.topAnchor),child.view.bottomAnchor.constraint(equalTo:view.bottomAnchor),child.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),child.view.trailingAnchor.constraint(equalTo:view.trailingAnchor)])
 }
}
// Mirrors the native SPNavigationController page assertion, including the
// module-qualified Objective-C protocol in Spotify 9.1.88.
class FixtureNavigation:UINavigationController {
 override func pushViewController(_ page:UIViewController,animated:Bool) {
  if ["SAPDownloadsSettings","SAPDetailsSettings"].contains(NSStringFromClass(type(of:page))) {
   for name in ["SPTPageController","_TtP19Tome_PageAttributes17SPTPageController_"] {
    guard let proto=NSProtocolFromString(name) else {preconditionFailure("missing protocol fixture")}
    precondition(page.conforms(to:proto),"native SPTPageController assertion: "+name)
   }
  }
  super.pushViewController(page,animated:animated)
 }
}
class ChromeHost:UIViewController {
 let nav:UINavigationController
 let mini=(NSClassFromString("_TtC18NowPlaying_BarImpl27NowPlayingBarViewController") as! UIViewController.Type).init()
 let bottom=UILabel()
 init(_ nav:UINavigationController){self.nav=nav;super.init(nibName:nil,bundle:nil)}
 required init?(coder:NSCoder){fatalError()}
 override func viewDidLoad(){
  super.viewDidLoad();view.backgroundColor = .black
  addChild(nav);view.addSubview(nav.view);nav.didMove(toParent:self)
  bottom.text="Главная             Поиск             Медиатека";bottom.textColor = .lightGray;bottom.backgroundColor = .black;bottom.textAlignment = .center;view.addSubview(bottom)
  addChild(mini);view.addSubview(mini.view);mini.didMove(toParent:self)
 }
 override func viewDidLayoutSubviews(){
  super.viewDidLayoutSubviews();nav.view.frame=view.bounds
  mini.view.frame=CGRect(x:8,y:view.bounds.height-146,width:view.bounds.width-16,height:56)
  bottom.frame=CGRect(x:0,y:view.bounds.height-90,width:view.bounds.width,height:90)
 }
}
@main class AppDelegate:UIResponder,UIApplicationDelegate {
 func application(_ application:UIApplication,didFinishLaunchingWithOptions opts:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {SAPInstallDownloadSettings();return true}
}
@objc(SAPFixtureSceneDelegate) class SceneDelegate:UIResponder,UIWindowSceneDelegate {
 var window:UIWindow?
 func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
  guard let windowScene=scene as? UIWindowScene else{return}
  let window=UIWindow(windowScene:windowScene);self.window=window
  let root=FixtureSettings();root.title="EeveeSpotify";let nav=FixtureNavigation(rootViewController:root)
  let chrome=ChromeHost(nav);window.rootViewController=chrome;window.overrideUserInterfaceStyle = .dark;window.makeKeyAndVisible()
  DispatchQueue.main.asyncAfter(deadline:.now()+1.5){
   let lists=root.view.subviews.flatMap{self.descendants($0)}.compactMap{$0 as? UIScrollView}
   guard let list=lists.first(where:{$0 is UICollectionView}),let entry=lists.first(where:{$0.accessibilityIdentifier=="SpotifyTrackDownloadsSection"}) as? UITableView else {self.write("NO_ENTRY");return}
   list.setContentOffset(CGPoint(x:0,y:max(-list.adjustedContentInset.top,list.contentSize.height-list.bounds.height+list.adjustedContentInset.bottom)),animated:false)
   DispatchQueue.main.asyncAfter(deadline:.now()+0.7){
    self.capture("root-settings")
    let cellRect=entry.convert(entry.rectForRow(at:IndexPath(row:1,section:0)),to:window)
    let miniTop=chrome.mini.view.convert(chrome.mini.view.bounds,to:window).minY
    self.write("root last row bottom=\(cellRect.maxY); mini top=\(miniTop)")
    precondition(cellRect.maxY<=miniTop-10,"root row under mini-player")
    if let cv=list as? UICollectionView, let footer=cv.collectionViewLayout.layoutAttributesForSupplementaryView(ofKind:UICollectionView.elementKindSectionFooter,at:IndexPath(item:0,section:3)) {
     let gap=entry.frame.minY-footer.frame.maxY;self.write("entry-to-reset-footer gap=\(gap)");precondition(abs(gap)<1,"entry separated by spacer")
    }
    let rect=entry.convert(entry.bounds,to:window)
    self.write("entry frame=\(rect); contentSize=\(list.contentSize); inset=\(list.contentInset); roots=\(root.children.count)")
    entry.delegate?.tableView?(entry,didSelectRowAt:IndexPath(row:0,section:0))
    DispatchQueue.main.asyncAfter(deadline:.now()+0.8){
     self.capture("downloads-top")
     guard let page=nav.topViewController as? UITableViewController else{return}
     precondition(page.tableView.numberOfSections==4)
     precondition(page.tableView.numberOfRows(inSection:1)==3,"quota/license/device rows missing")
     let modeCell=page.tableView.dataSource!.tableView(page.tableView,cellForRowAt:IndexPath(row:0,section:1))
     precondition((modeCell.contentConfiguration as? UIListContentConfiguration)?.text=="Configured request mode","selected mode must not be presented as verified execution")
     precondition(!modeCell.isUserInteractionEnabled,"mode 0 must be read-only")
     let originalSnapshot=page.value(forKey:"snapshot") as! [String:Any]
     var modeOneSnapshot=originalSnapshot
     modeOneSnapshot["key_request_mode"]=["configured_mode":1,"restore_zero_supported":false,"mode_one_confirmed":true,"configuration_source":"verified_direct_instruction"]
     page.setValue(modeOneSnapshot,forKey:"snapshot")
     let modeOneCell=page.tableView.dataSource!.tableView(page.tableView,cellForRowAt:IndexPath(row:0,section:1))
     precondition((modeOneCell.accessoryView as? UILabel)?.text=="1")
     precondition((modeOneCell.accessoryView as? UILabel)?.textColor==UIColor.systemRed,"mode 1 must remain red")
     precondition(!modeOneCell.isUserInteractionEnabled,"mode 1 must not enable mode selection")
     page.setValue(originalSnapshot,forKey:"snapshot")
     let reuseTable=ReusingSettingsTable(frame:.zero,style:.insetGrouped)
     let disabled=page.tableView.dataSource!.tableView(reuseTable,cellForRowAt:IndexPath(row:0,section:1))
     precondition(!disabled.isUserInteractionEnabled)
     reuseTable.recycled=disabled
     for _ in 0..<3 {for (section,row) in [(0,0),(0,1),(1,2),(1,1),(2,0),(2,1),(2,2),(3,0),(3,1)] {
      let action=page.tableView.dataSource!.tableView(reuseTable,cellForRowAt:IndexPath(row:row,section:section))
      precondition(action === disabled && action.isUserInteractionEnabled && action.selectionStyle == .default,"recycled read-only mode cell disabled an action")
     }}
     self.write("PASS: every action remains tappable after repeated reuse of the disabled mode row")
     let modeFooter=page.tableView.dataSource!.tableView?(page.tableView,titleForFooterInSection:1) ?? ""
     precondition(!modeFooter.contains("5 licenses = up to 5 devices with offline music."))
     precondition(!modeFooter.lowercased().contains("recovery"))
     let refreshCell=page.tableView.dataSource!.tableView(page.tableView,cellForRowAt:IndexPath(row:1,section:1))
     precondition((refreshCell.contentConfiguration as? UIListContentConfiguration)?.text=="Refresh quotas and licenses")
     for (row,title) in [(2,"Offline devices")] {
      let cell=page.tableView.dataSource!.tableView(page.tableView,cellForRowAt:IndexPath(row:row,section:1))
      precondition((cell.contentConfiguration as? UIListContentConfiguration)?.text==title)
     }
     precondition(page.title=="Pixie Download Manager","Pixie must remain in English")
     for section in 0..<page.tableView.numberOfSections {for row in 0..<page.tableView.numberOfRows(inSection:section) {
      let cell=page.tableView.dataSource!.tableView(page.tableView,cellForRowAt:IndexPath(row:row,section:section))
      if let content=cell.contentConfiguration as? UIListContentConfiguration {
       precondition(!(content.text ?? "").contains("WAV"),"WAV row still present")
       precondition(!(content.text ?? "").contains("Заглушить") && !(content.text ?? "").contains("Mute audio"),"mute row still present")
       precondition(!(content.text ?? "").contains("Export") && !(content.text ?? "").contains("Send log"),"duplicate log export row")
      }
     }}
     page.tableView.scrollToRow(at:IndexPath(row:0,section:2),at:.middle,animated:false)
     DispatchQueue.main.asyncAfter(deadline:.now()+0.5){
      let togglePath=IndexPath(row:0,section:2)
      if let toggle=page.tableView.cellForRow(at:togglePath)?.accessoryView as? UISwitch {
       precondition(!toggle.isOn,"diagnostics must default off")
       toggle.isOn=true;toggle.sendActions(for:.valueChanged)
       precondition((page.tableView.cellForRow(at:togglePath)?.accessoryView as? UISwitch)?.isOn == true)
       if let current=page.tableView.cellForRow(at:togglePath)?.accessoryView as? UISwitch {current.isOn=false;current.sendActions(for:.valueChanged)}
       precondition((page.tableView.cellForRow(at:togglePath)?.accessoryView as? UISwitch)?.isOn == false)
       self.write("PASS: legacy and module-qualified native page protocols; diagnostics switch defaults OFF and toggles ON/OFF")
      } else {preconditionFailure("diagnostics switch not visible")}

      page.tableView.setContentOffset(CGPoint(x:0,y:max(0,page.tableView.contentSize.height-page.tableView.bounds.height+page.tableView.adjustedContentInset.bottom)),animated:false)
      page.tableView.layoutIfNeeded()
      self.capture("downloads-bottom")
      let last=page.tableView.convert(page.tableView.rectForRow(at:IndexPath(row:1,section:3)),to:window)
      self.write("downloads last row bottom=\(last.maxY); mini top=\(miniTop); inset=\(page.tableView.contentInset)")
      precondition(last.maxY<=miniTop-10,"downloads row under mini-player")
      page.tableView.delegate?.tableView?(page.tableView,didSelectRowAt:IndexPath(row:1,section:2))
      DispatchQueue.main.asyncAfter(deadline:.now()+0.7){
       self.capture("diagnostics")
       guard let details=nav.topViewController as? UITableViewController else {preconditionFailure("missing diagnostics page")}
       precondition(details.title=="Audio diagnostics" && details.tableView.numberOfRows(inSection:1)==8)
       let labels=["Downloaded","Downloading","Waiting","Paused","Errors","Limit reached","Not downloaded","Expired"]
       for row in 0..<8 {
        let cell=details.tableView.dataSource!.tableView(details.tableView,cellForRowAt:IndexPath(row:row,section:1))
        precondition(cell.textLabel?.text==labels[row] && cell.detailTextLabel?.text != "Unavailable")
       }
       details.tableView.scrollToRow(at:IndexPath(row:0,section:1),at:.top,animated:false)
       details.tableView.layoutIfNeeded();self.capture("diagnostics-status")
       func inspectManager(_ remaining:Int) {
        nav.popToViewController(page,animated:false)
        page.tableView.delegate?.tableView?(page.tableView,didSelectRowAt:IndexPath(row:2,section:1))
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
         guard let devices=nav.topViewController as? UITableViewController else {preconditionFailure("missing device page")}
         devices.loadViewIfNeeded()
         precondition(devices.title=="Offline devices" && devices.tableView.numberOfRows(inSection:0)==2,"device route did not finish")
         precondition(devices.tableView.style == .insetGrouped && devices.tableView.numberOfSections==3)
         for (section,title) in ["Devices","iPhone (current)","Source checks"].enumerated() {
          precondition(devices.tableView.dataSource?.tableView?(devices.tableView,titleForHeaderInSection:section)==title,"offline section order changed")
         }
         precondition(devices.tableView.numberOfRows(inSection:1)==1 && devices.tableView.numberOfRows(inSection:2)==3)
         let old=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:0))
         let other=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:1,section:0))
         let originalPlan=devices.value(forKey:"plan") as! [String:Any]
         let fullRecords=originalPlan["devices"] as! [[String:Any]]
         precondition(fullRecords.count==4 && fullRecords.first?["selection_token"] as? String == "historical-token","presentation filter changed the original plan")
         let enabledRecords=devices.value(forKey:"devices") as! [[String:Any]]
         precondition(enabledRecords.compactMap{$0["selection_token"] as? String} == ["old-token","other-token"],"filtered rows lost original order or selection tokens")
         precondition(enabledRecords.allSatisfy{($0["offline_enabled"] as? Bool)==true},"inactive record leaked into device list")
         let inactiveCurrent=devices.value(forKey:"currentDevice") as! [String:Any]
         precondition(inactiveCurrent["device_id"] as? String == "this-device" && inactiveCurrent["offline_enabled"] as? Bool == false,"filter changed current-device identity or status")
         let enable=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:1))
         precondition(enable.isUserInteractionEnabled && (enable.contentConfiguration as? UIListContentConfiguration)?.text == "Enable offline on this device","hidden inactive current record lost its separate enable action")
         for cell in [old,other] {
          guard let content=cell.contentConfiguration as? UIListContentConfiguration else {preconditionFailure("missing native device content")}
          precondition(content.image==nil && content.imageProperties.reservedLayoutSize.width==0,"device has an icon tile")
          precondition(content.text=="iPhone" && content.secondaryText?.contains("Device ")==true,"duplicate device names lost identifying details")
          precondition(cell.backgroundColor==UIColor.secondarySystemGroupedBackground && cell.accessoryType == .none)
         }
         precondition(old.accessoryView==nil && other.accessoryView==nil,"a different active iPhone was marked as this device")
         for row in 0..<2 {
          let trailing=devices.tableView.delegate?.tableView?(devices.tableView,trailingSwipeActionsConfigurationForRowAt:IndexPath(row:row,section:0))
          precondition(trailing?.actions.first?.title=="Remove" && trailing?.actions.first?.style == .destructive && trailing?.performsFirstActionWithFullSwipe==false)
          precondition(devices.tableView.delegate?.tableView?(devices.tableView,leadingSwipeActionsConfigurationForRowAt:IndexPath(row:row,section:0)) == nil,"enabled row offered an enable swipe")
         }
         precondition(devices.tableView.delegate?.tableView?(devices.tableView,trailingSwipeActionsConfigurationForRowAt:IndexPath(row:2,section:0)) == nil,"hidden historical row offered Remove")
         var emptyPlan=originalPlan
         emptyPlan["devices"]=fullRecords.map { record -> [String:Any] in var disabled=record;disabled["offline_enabled"]=false;return disabled }
         devices.setValue(emptyPlan,forKey:"plan");devices.tableView.reloadData()
         precondition((devices.value(forKey:"devices") as! [[String:Any]]).isEmpty && devices.tableView.numberOfRows(inSection:0)==1,"empty active list did not show one placeholder")
         let placeholder=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:0))
         precondition(placeholder.textLabel?.text=="No offline-enabled devices")
         precondition(devices.tableView.delegate?.tableView?(devices.tableView,trailingSwipeActionsConfigurationForRowAt:IndexPath(row:0,section:0)) == nil,"placeholder offered Remove")
         precondition(devices.tableView.delegate?.tableView?(devices.tableView,leadingSwipeActionsConfigurationForRowAt:IndexPath(row:0,section:0)) == nil,"placeholder offered an enable swipe")
         var currentEnabledPlan=originalPlan
         currentEnabledPlan["devices"]=fullRecords.map { record -> [String:Any] in
          var updated=record;if (record["is_current_device"] as? Bool)==true {updated["offline_enabled"]=true};return updated
         }
         devices.setValue(currentEnabledPlan,forKey:"plan");devices.tableView.reloadData()
         let withCurrent=devices.value(forKey:"devices") as! [[String:Any]]
         precondition(withCurrent.compactMap{$0["selection_token"] as? String} == ["old-token","current-token","other-token"])
         for row in 0..<3 {
          let cell=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:row,section:0))
          if row==1 {
           precondition((cell.contentConfiguration as? UIListContentConfiguration)?.text=="iPhone (current)" && cell.accessibilityLabel=="iPhone (current)","exact current-device name marker lost")
          } else {precondition((cell.contentConfiguration as? UIListContentConfiguration)?.text=="iPhone","current marker matched an iPhone name instead of its exact identity")}
          precondition(cell.accessoryView==nil,"current marker should be part of the name")
         }
         var unknownCurrentPlan=originalPlan
         unknownCurrentPlan["devices"]=fullRecords.map { record -> [String:Any] in var unknown=record;unknown["is_current_device"]=false;return unknown }
         devices.setValue(unknownCurrentPlan,forKey:"plan");devices.tableView.reloadData()
         precondition(devices.tableView.dataSource?.tableView?(devices.tableView,titleForHeaderInSection:1)=="Current device","unknown identity received a current marker")
         let unknownEnable=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:1))
         precondition(!unknownEnable.isUserInteractionEnabled,"unknown current identity offered enable")
         devices.setValue(originalPlan,forKey:"plan");devices.tableView.reloadData()
         precondition((devices.value(forKey:"devices") as! [[String:Any]]).compactMap{$0["selection_token"] as? String} == ["old-token","other-token"],"restoring the plan left stale visible records")
         if remaining>1 {inspectManager(remaining-1);return}
         devices.view.layoutIfNeeded();self.capture("offline-devices")
         devices.tableView.setContentOffset(CGPoint(x:0,y:max(0,devices.tableView.contentSize.height-devices.tableView.bounds.height+devices.tableView.adjustedContentInset.bottom)),animated:false)
         devices.tableView.layoutIfNeeded()
         let enableRect=devices.tableView.convert(devices.tableView.rectForRow(at:IndexPath(row:0,section:1)),to:window)
         precondition(enableRect.maxY<=miniTop-10,"device enable row under mini-player")
         self.capture("offline-devices-bottom")
         func exerciseEnable(_ times:Int) {
          devices.tableView.delegate?.tableView?(devices.tableView,didSelectRowAt:IndexPath(row:0,section:1))
          DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
           let disabled=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:1))
           precondition(!disabled.isUserInteractionEnabled,"mismatched source enabled mutation")
           precondition(devices.tableView.delegate?.tableView?(devices.tableView,trailingSwipeActionsConfigurationForRowAt:IndexPath(row:0,section:0)) == nil,"mismatch offered swipe")
           devices.presentedViewController?.dismiss(animated:false)
           if let refresh=devices.navigationItem.rightBarButtonItem,let action=refresh.action,let target=refresh.target as? NSObject {target.perform(action)}
           let enabled=devices.tableView.dataSource!.tableView(devices.tableView,cellForRowAt:IndexPath(row:0,section:1))
           precondition(enabled.isUserInteractionEnabled,"failed completion left device manager busy")
           if times>1 {DispatchQueue.main.asyncAfter(deadline:.now()+0.2){exerciseEnable(times-1)};return}
           self.write("PASS: repeated enable error completion clears busy state; source mismatch blocks mutations until refresh")
           self.write("PASS: status counts inside Audio diagnostics; repeated offline manager navigation; active-only device rows preserve order and tokens; full plan and inactive current identity retained; empty active placeholder has no Remove; exact current name marker for enabled/disabled identity; no marker or enable for unknown identity; guarded Remove without full swipe; no enable swipes")
           self.write("PASS: entry spacing, mini-player clearance, navigation and native pages rendered")
          }
         }
         exerciseEnable(3)
        }
       }
       inspectManager(3)
      }
     }
    }
   }
  }
 }
 func descendants(_ view:UIView)->[UIView]{[view]+view.subviews.flatMap{descendants($0)}}
 func capture(_ name:String){guard let w=window else{return};let image=UIGraphicsImageRenderer(bounds:w.bounds).image{_ in w.drawHierarchy(in:w.bounds,afterScreenUpdates:true)};try? image.pngData()?.write(to:FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent(name+".png"))}
 func write(_ value:String){let u=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("result.log");let old=(try?String(contentsOf:u,encoding:.utf8)) ?? "";try?(old+value+"\n").write(to:u,atomically:true,encoding:.utf8)}
}
