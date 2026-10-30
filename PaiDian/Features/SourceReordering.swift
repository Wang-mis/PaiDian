import SwiftUI
import UIKit

struct SourceListInput: Equatable {
    var scripts: [SourceScript]
    var busy = false
    var failure: String?
    var updateMessage: String?
    var updateURL: URL?
    var notice: String?
}
enum SourceListAction { case importFile,importURL,replaceFile(UUID),replaceURL(UUID),delete(UUID),retry(UUID),error(String),retryAll,openUpdate(URL) }
struct NativeSourceList: UIViewControllerRepresentable {
    var input: SourceListInput
    var action: (SourceListAction)->Void
    var save: @MainActor ([UUID]) async -> Bool
    func makeUIViewController(context:Context)->SourceListController { SourceListController(input:input,action:action,save:save) }
    func updateUIViewController(_ controller:SourceListController,context:Context) { controller.update(input:input,action:action,save:save) }
    static func dismantleUIViewController(_ controller:SourceListController,coordinator:()) { controller.endReordering(cancelled:true) }
}

/// One UIKit collection view owns the gesture, item movement, and final order.
/// SwiftUI does not move or replace rows underneath an active drag.
@MainActor final class SourceListController: UICollectionViewController,UIGestureRecognizerDelegate {
    private var input: SourceListInput
    private var action: (SourceListAction)->Void
    private var save: @MainActor ([UUID]) async -> Bool
    private(set) var displayedScripts: [SourceScript]
    private(set) var isReordering=false
    private(set) var isSaving=false
    private var pendingOrder: [UUID]?
    private var originalOrder: [UUID]?
    private var gesture: UILongPressGestureRecognizer!
    private(set) var movementPositionUpdateCount=0
    private(set) var movementTargetChangeCount=0
    private(set) var lastMovementPosition:CGPoint?
    private var acceptedMovementTarget:IndexPath?
    private struct MovementBounds {
        let firstCenter:CGFloat
        let lastCenter:CGFloat
    }
    private enum MovementEdge { case first,last }
    private var movementBounds:MovementBounds?
    private var movementEdge:MovementEdge?
    private var fingerViewportY:CGFloat?
    private var lastMovementOffset:CGPoint?
    var displayedOrder: [UUID] { displayedScripts.map(\.id) }
    init(input:SourceListInput,action:@escaping (SourceListAction)->Void,save:@escaping @MainActor ([UUID]) async -> Bool) {
        self.input=input;self.action=action;self.save=save;displayedScripts=input.scripts
        let layout=UICollectionViewCompositionalLayout { section,environment in
            var configuration=UICollectionLayoutListConfiguration(appearance:.insetGrouped)
            configuration.backgroundColor = .clear
            configuration.headerMode = section == 1 ? .supplementary : .none
            configuration.footerMode = section < 2 ? .supplementary : .none
            return NSCollectionLayoutSection.list(using:configuration,layoutEnvironment:environment)
        }
        super.init(collectionViewLayout:layout)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad();view.backgroundColor = .clear;collectionView.backgroundColor = .clear
        collectionView.register(SourceNativeCell.self,forCellWithReuseIdentifier:"source")
        collectionView.register(UICollectionViewListCell.self,forCellWithReuseIdentifier:"action")
        for kind in [UICollectionView.elementKindSectionHeader,UICollectionView.elementKindSectionFooter] { collectionView.register(SourceListSupplement.self,forSupplementaryViewOfKind:kind,withReuseIdentifier:"text") }
        gesture=UILongPressGestureRecognizer(target:self,action:#selector(handleLongPress(_:)))
        gesture.minimumPressDuration=0.3;gesture.delegate=self;collectionView.addGestureRecognizer(gesture)
    }
    func update(input:SourceListInput,action:@escaping (SourceListAction)->Void,save:@escaping @MainActor ([UUID]) async -> Bool) {
        let old=self.input;self.input=input;self.action=action;self.save=save
        if isReordering {
            if Set(input.scripts.map(\.id)) != Set(displayedOrder) { endReordering(cancelled:true) }
            return
        }
        if let pendingOrder {
            if input.scripts.map(\.id) == pendingOrder { self.pendingOrder=nil }
            else if Set(input.scripts.map(\.id)) == Set(pendingOrder) { return }
            else { self.pendingOrder=nil }
        }
        if old != input || displayedScripts != input.scripts { applyAuthoritativeInput(reload:old.failure != input.failure || old.updateMessage != input.updateMessage || old.updateURL != input.updateURL || old.notice != input.notice) }
    }
    private func applyAuthoritativeInput(reload:Bool = false) {
        guard !isReordering,pendingOrder == nil else { return }
        let changed=displayedScripts != input.scripts
        displayedScripts=input.scripts
        if isViewLoaded {
            // No reload is needed for an order acknowledgement: UIKit already moved the cells.
            if changed || reload { collectionView.reloadData() }
            else { for cell in collectionView.visibleCells { if let path=collectionView.indexPath(for:cell) { configure(cell,at:path) } } }
        }
    }
    override func numberOfSections(in collectionView:UICollectionView)->Int { 3 }
    private var actionRows: [(String,String,SourceListAction?)] {
        var rows:[(String,String,SourceListAction?)]=[("从文件导入","folder",.importFile),("从 URL 导入","link",.importURL)]
        if let failure=input.failure { rows.append((failure,"exclamationmark.circle",.error(failure)));rows.append(("重新初始化","arrow.clockwise",.retryAll)) }
        if let message=input.updateMessage { rows.append((message,"info.circle",nil)) }
        if let url=input.updateURL { rows.append(("查看更新页面","arrow.up.right",.openUpdate(url))) }
        return rows
    }
    override func collectionView(_ collectionView:UICollectionView,numberOfItemsInSection section:Int)->Int {
        switch section { case 0:return actionRows.count;case 1:return max(1,displayedScripts.count);default:return input.notice == nil ? 0 : 1 }
    }
    override func collectionView(_ collectionView:UICollectionView,cellForItemAt indexPath:IndexPath)->UICollectionViewCell {
        let cell=collectionView.dequeueReusableCell(withReuseIdentifier:indexPath.section == 1 && !displayedScripts.isEmpty ? "source" : "action",for:indexPath)
        configure(cell,at:indexPath);return cell
    }
    private func configure(_ cell:UICollectionViewCell,at path:IndexPath) {
        guard let list=cell as? UICollectionViewListCell else { return }
        if path.section == 1,!displayedScripts.isEmpty {
            guard displayedScripts.indices.contains(path.item),let row=cell as? SourceNativeCell else { return }
            let script=displayedScripts[path.item]
            row.configure(script:script,enabled:!input.busy && !isSaving,action:action,
                moveUp:{ [weak self] in self?.moveAccessibly(id:script.id,delta:-1) },moveDown:{ [weak self] in self?.moveAccessibly(id:script.id,delta:1) })
        } else {
            var config=UIListContentConfiguration.cell();config.textProperties.numberOfLines=0
            if path.section == 0 {
                guard actionRows.indices.contains(path.item) else { return }
                let row=actionRows[path.item];config.text=row.0;config.image=UIImage(systemName:row.1)
                config.textProperties.color=row.2 == nil ? .secondaryLabel : .label
            } else { config.text=path.section == 1 ? "尚未导入音源" : input.notice;config.textProperties.color = .secondaryLabel }
            list.contentConfiguration=config
            list.accessibilityIdentifier=path.section == 0 && path.item == 0 ? "importSourceFile" : nil
        }
    }
    override func collectionView(_ collectionView:UICollectionView,viewForSupplementaryElementOfKind kind:String,at path:IndexPath)->UICollectionReusableView {
        let view=collectionView.dequeueReusableSupplementaryView(ofKind:kind,withReuseIdentifier:"text",for:path) as! SourceListSupplement
        view.label.text=kind == UICollectionView.elementKindSectionHeader ? "已导入音源" : (path.section == 0 ? "支持洛雪移动版 API 2.0.0 的在线音源脚本。请仅导入信任的脚本。" : "按从上到下的顺序尝试音源")
        return view
    }
    override func collectionView(_ collectionView:UICollectionView,didSelectItemAt path:IndexPath) {
        collectionView.deselectItem(at:path,animated:true)
        guard !input.busy,!isSaving,path.section == 0,actionRows.indices.contains(path.item),let command=actionRows[path.item].2 else { return }
        action(command)
    }
    override func collectionView(_ collectionView:UICollectionView,canMoveItemAt path:IndexPath)->Bool { path.section == 1 && displayedScripts.indices.contains(path.item) && !input.busy && !isSaving }
    override func collectionView(_ collectionView:UICollectionView,moveItemAt source:IndexPath,to destination:IndexPath) {
        guard source.section == 1,destination.section == 1,displayedScripts.indices.contains(source.item),displayedScripts.indices.contains(destination.item) else { return }
        let script=displayedScripts.remove(at:source.item);displayedScripts.insert(script,at:destination.item)
        if !isReordering { commitDisplayedOrder() }
    }
    override func collectionView(_ collectionView:UICollectionView,targetIndexPathForMoveOfItemFromOriginalIndexPath original:IndexPath,atCurrentIndexPath current:IndexPath,toProposedIndexPath proposed:IndexPath)->IndexPath {
        updateMovementEdge()
        let target:IndexPath
        if movementEdge == .first { target=IndexPath(item:0,section:1) }
        else if movementEdge == .last { target=IndexPath(item:max(0,displayedScripts.count-1),section:1) }
        else if proposed.section < 1 { target=IndexPath(item:0,section:1) }
        else if proposed.section > 1 { target=IndexPath(item:max(0,displayedScripts.count-1),section:1) }
        else { target=IndexPath(item:min(max(0,proposed.item),max(0,displayedScripts.count-1)),section:1) }
        if acceptedMovementTarget != target { movementTargetChangeCount+=1;acceptedMovementTarget=target }
        return target
    }
    func gestureRecognizerShouldBegin(_ recognizer:UIGestureRecognizer)->Bool {
        canBegin(at:recognizer.location(in:collectionView))
    }
    private func canBegin(at point:CGPoint)->Bool {
        guard !isReordering,!isSaving,pendingOrder == nil,!input.busy,
              let path=collectionView.indexPathForItem(at:point),path.section == 1,displayedScripts.indices.contains(path.item),
              let cell=collectionView.cellForItem(at:path) else { return false }
        let local=cell.convert(point,from:collectionView)
        return local.x >= 0 && local.x <= 64
    }
    @discardableResult func beginReordering(at point:CGPoint)->Bool {
        guard canBegin(at:point),let path=collectionView.indexPathForItem(at:point),
              let first=collectionView.layoutAttributesForItem(at:IndexPath(item:0,section:1))?.frame,
              let last=collectionView.layoutAttributesForItem(at:IndexPath(item:displayedScripts.count-1,section:1))?.frame else { return false }
        // Capture slot centers before UIKit replaces the dragged row with its moving placeholder.
        // Reading those animated attributes on every event creates a feedback loop at either end.
        movementBounds=MovementBounds(firstCenter:first.midY,lastCenter:last.midY)
        movementEdge=nil;fingerViewportY=point.y-collectionView.contentOffset.y;lastMovementOffset=nil
        originalOrder=displayedOrder;isReordering=true
        movementPositionUpdateCount=0;movementTargetChangeCount=0;lastMovementPosition=nil;acceptedMovementTarget=path
        if !collectionView.beginInteractiveMovementForItem(at:path) { isReordering=false;originalOrder=nil;clearMovementGeometry();return false }
        return true
    }
    func updateReordering(at point:CGPoint) {
        guard isReordering,let bounds=movementBounds,!displayedScripts.isEmpty else { return }
        fingerViewportY=point.y-collectionView.contentOffset.y
        updateMovementEdge()
        let y:CGFloat
        switch movementEdge {
        case .first:y=bounds.firstCenter
        case .last:y=bounds.lastCenter
        case nil:y=min(max(point.y,bounds.firstCenter),bounds.lastCenter)
        }
        let target=CGPoint(x:collectionView.bounds.midX,y:y)
        // A stationary finger (including tiny tremors) must not repeatedly drive UIKit movement.
        // Offset changes are still forwarded so edge scrolling can continue through a long list.
        if let lastMovementPosition,let lastMovementOffset,
           abs(target.x-lastMovementPosition.x)<0.5,abs(target.y-lastMovementPosition.y)<0.5,
           lastMovementOffset == collectionView.contentOffset { return }
        movementPositionUpdateCount+=1;lastMovementPosition=target;lastMovementOffset=collectionView.contentOffset
        collectionView.updateInteractiveMovementTargetPosition(target)
    }
    private func updateMovementEdge() {
        guard let bounds=movementBounds,let fingerViewportY else { return }
        let y=fingerViewportY+collectionView.contentOffset.y
        // Hysteresis prevents a small tremor around a slot center from releasing/reacquiring it.
        if movementEdge == .first,y <= bounds.firstCenter+10 { return }
        if movementEdge == .last,y >= bounds.lastCenter-10 { return }
        if y <= bounds.firstCenter { movementEdge = .first }
        else if y >= bounds.lastCenter { movementEdge = .last }
        else { movementEdge=nil }
    }
    private func clearMovementGeometry() {
        movementBounds=nil;movementEdge=nil;fingerViewportY=nil;lastMovementOffset=nil
    }
    func endReordering(cancelled:Bool) {
        guard isReordering else { return }
        if cancelled { collectionView.cancelInteractiveMovement();isReordering=false;originalOrder=nil;applyAuthoritativeInput() }
        else { collectionView.endInteractiveMovement();isReordering=false;commitDisplayedOrder();originalOrder=nil }
        clearMovementGeometry()
    }
    @objc private func handleLongPress(_ recognizer:UILongPressGestureRecognizer) {
        let point=recognizer.location(in:collectionView)
        switch recognizer.state {
        case .began:_ = beginReordering(at:point)
        case .changed:updateReordering(at:point)
        case .ended:endReordering(cancelled:false)
        case .cancelled,.failed:endReordering(cancelled:true)
        default:break
        }
    }
    private func commitDisplayedOrder() {
        let order=displayedOrder
        guard pendingOrder == nil,order != input.scripts.map(\.id) else { return }
        pendingOrder=order;isSaving=true
        Task { [weak self,save] in
            let success=await save(order)
            guard let self else { return };self.isSaving=false
            if !success { self.pendingOrder=nil;self.applyAuthoritativeInput() }
            else if self.input.scripts.map(\.id) == order { self.pendingOrder=nil;self.applyAuthoritativeInput() }
            // Otherwise retain the local order until update receives the saved snapshot.
        }
    }
    private func moveAccessibly(id:UUID,delta:Int) {
        guard !isReordering,!isSaving,pendingOrder == nil,!input.busy,let from=displayedScripts.firstIndex(where:{$0.id == id}),displayedScripts.indices.contains(from+delta) else { return }
        let row=displayedScripts.remove(at:from);displayedScripts.insert(row,at:from+delta)
        collectionView.moveItem(at:IndexPath(item:from,section:1),to:IndexPath(item:from+delta,section:1));commitDisplayedOrder()
    }
}

private final class SourceNativeCell:UICollectionViewListCell {
    private let handle=UIButton(type:.system),name=UILabel(),version=UILabel(),warning=UIImageView(image:UIImage(systemName:"exclamationmark.circle")),menuButton=UIButton(type:.system)
    override init(frame:CGRect) {
        super.init(frame:frame)
        handle.setImage(UIImage(systemName:"line.3.horizontal"),for:.normal);handle.tintColor = .secondaryLabel
        name.font = .preferredFont(forTextStyle:.headline);name.numberOfLines=0;name.adjustsFontForContentSizeCategory=true
        version.font = .preferredFont(forTextStyle:.caption1);version.textColor = .secondaryLabel;version.adjustsFontForContentSizeCategory=true
        warning.tintColor = .systemRed;warning.contentMode = .scaleAspectFit
        let title=UIStackView(arrangedSubviews:[name,warning]);title.spacing=6;title.alignment = .center
        let text=UIStackView(arrangedSubviews:[title,version]);text.axis = .vertical;text.spacing=6
        menuButton.setImage(UIImage(systemName:"ellipsis"),for:.normal);menuButton.tintColor = .secondaryLabel;menuButton.showsMenuAsPrimaryAction=true
        let stack=UIStackView(arrangedSubviews:[handle,text,menuButton]);stack.spacing=10;stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints=false;contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:contentView.leadingAnchor,constant:4),stack.trailingAnchor.constraint(equalTo:contentView.trailingAnchor,constant:-8),stack.topAnchor.constraint(equalTo:contentView.topAnchor,constant:8),stack.bottomAnchor.constraint(equalTo:contentView.bottomAnchor,constant:-8),handle.widthAnchor.constraint(equalToConstant:44),handle.heightAnchor.constraint(equalToConstant:44),menuButton.widthAnchor.constraint(equalToConstant:44),menuButton.heightAnchor.constraint(equalToConstant:44),warning.widthAnchor.constraint(equalToConstant:16),warning.heightAnchor.constraint(equalToConstant:16)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(script:SourceScript,enabled:Bool,action:@escaping (SourceListAction)->Void,moveUp:@escaping ()->Void,moveDown:@escaping ()->Void) {
        name.text=script.name;version.text=script.version.map { "版本 "+$0 } ?? "版本未知";warning.isHidden=script.initializationError == nil
        handle.accessibilityLabel="调整"+script.name+"顺序";handle.accessibilityIdentifier="sourceHandle-"+script.id.uuidString
        handle.accessibilityHint="长按并上下拖动";handle.isEnabled=enabled
        handle.accessibilityCustomActions=[UIAccessibilityCustomAction(name:"上移") { _ in moveUp();return true },UIAccessibilityCustomAction(name:"下移") { _ in moveDown();return true }]
        var items:[UIMenuElement]=[]
        if let error=script.initializationError { items.append(UIAction(title:"查看初始化错误") { _ in action(.error(error)) });items.append(UIAction(title:"重试初始化") { _ in action(.retry(script.id)) }) }
        items.append(UIAction(title:"替换文件") { _ in action(.replaceFile(script.id)) });items.append(UIAction(title:"从 URL 替换") { _ in action(.replaceURL(script.id)) })
        items.append(UIAction(title:"删除",attributes:.destructive) { _ in action(.delete(script.id)) })
        menuButton.menu=UIMenu(children:items);menuButton.accessibilityLabel=script.name+"操作";menuButton.isEnabled=enabled
    }
}
private final class SourceListSupplement:UICollectionReusableView {
    let label=UILabel()
    override init(frame:CGRect) {
        super.init(frame:frame);label.font = .preferredFont(forTextStyle:.footnote);label.textColor = .secondaryLabel;label.numberOfLines=0;label.adjustsFontForContentSizeCategory=true
        label.translatesAutoresizingMaskIntoConstraints=false;addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:20),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-20),label.topAnchor.constraint(equalTo:topAnchor,constant:8),label.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-8)])
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
}
