import SwiftUI
import UIKit

/// A scoped UIKit scroll surface provides drag/deceleration completion on iOS 17.
struct LyricsScroller: UIViewRepresentable {
    var lines: [LyricLine]
    var currentIndex: Int?
    var offsetMS: Int64
    var settings: AppSettings
    var canSeek: Bool
    var reduceMotion: Bool
    var isActive = true
    var onConfirm: (LyricLine) -> Void
    var onToggle: () -> Void
    func makeUIView(context: Context) -> LyricsScrollSurface { LyricsScrollSurface() }
    func updateUIView(_ view: LyricsScrollSurface, context: Context) {
        view.onConfirm = onConfirm; view.onToggle = onToggle
        view.setActive(isActive)
        view.configure(lines: lines, current: currentIndex, offset: offsetMS, settings: settings, canSeek: canSeek, reduceMotion: reduceMotion)
    }
    static func dismantleUIView(_ view: LyricsScrollSurface, coordinator: ()) { view.invalidate() }
}

@MainActor final class LyricsScrollSurface: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let indicator = UIView()
    private let rule = UIView()
    private let time = UILabel()
    private let play = UIButton(type: .system)
    private var rows: [UIView] = []
    private var labels: [(UILabel, UILabel?)] = []
    private(set) var browsing = LyricBrowsingState()
    private var lines: [LyricLine] = []
    private var settings = AppSettings()
    private var current: Int?
    private var offset: Int64 = 0
    private var canSeek = false
    private var reduceMotion = false
    private var isActive = true
    private var lastSize = CGSize.zero
    private var contentCategory: UIContentSizeCategory?
    private var timeout: Task<Void, Never>?
    var onConfirm: ((LyricLine) -> Void)?
    var onToggle: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "lyricsViewport"
        scrollView.delegate = self; scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceVertical = true; scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView); scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scrollView.leadingAnchor.constraint(equalTo:leadingAnchor),scrollView.trailingAnchor.constraint(equalTo:trailingAnchor),scrollView.topAnchor.constraint(equalTo:topAnchor),scrollView.bottomAnchor.constraint(equalTo:bottomAnchor)])
        stack.axis = .vertical; stack.alignment = .fill; stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:scrollView.contentLayoutGuide.leadingAnchor,constant:48),stack.trailingAnchor.constraint(equalTo:scrollView.contentLayoutGuide.trailingAnchor,constant:-48),stack.topAnchor.constraint(equalTo:scrollView.contentLayoutGuide.topAnchor),stack.bottomAnchor.constraint(equalTo:scrollView.contentLayoutGuide.bottomAnchor),stack.widthAnchor.constraint(equalTo:scrollView.frameLayoutGuide.widthAnchor,constant:-96)])
        indicator.isUserInteractionEnabled = false; indicator.layer.cornerRadius = 9
        addSubview(indicator); rule.backgroundColor = UIColor.white.withAlphaComponent(0.12); indicator.addSubview(rule)
        time.textColor = UIColor.white.withAlphaComponent(0.65); time.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); time.textAlignment = .center
        indicator.addSubview(time)
        play.setImage(UIImage(systemName:"play.fill"),for:.normal); play.tintColor = UIColor.white.withAlphaComponent(0.7)
        play.accessibilityLabel = "从选中歌词开始播放"; play.accessibilityIdentifier = "confirmLyric"
        play.addTarget(self,action:#selector(confirmSelection),for:.touchUpInside); addSubview(play)
        let tap = UITapGestureRecognizer(target:self,action:#selector(tapped(_:))); tap.delegate = self
        tap.require(toFail:scrollView.panGestureRecognizer); addGestureRecognizer(tap)
        let mask = CAGradientLayer(); mask.colors = [UIColor.clear.cgColor,UIColor.black.cgColor,UIColor.black.cgColor,UIColor.clear.cgColor]; mask.locations = [0,0.10,0.90,1]; layer.mask = mask
        updateSelectionAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setActive(_ active:Bool) {
        guard active != isActive else { return };isActive=active
        if !active { invalidate();scrollView.setContentOffset(scrollView.contentOffset,animated:false) }
        else { updateSelectionAppearance();centerCurrent(animated:false) }
    }
    func configure(lines: [LyricLine], current: Int?, offset: Int64, settings: AppSettings, canSeek: Bool, reduceMotion: Bool) {
        let rebuild = self.lines != lines || self.settings.lyricFontSize != settings.lyricFontSize || self.settings.lyricLineSpacing != settings.lyricLineSpacing || self.settings.lyricCurrentLineScale != settings.lyricCurrentLineScale || contentCategory != traitCollection.preferredContentSizeCategory
        let changed = self.current != current || self.offset != offset
        self.lines = lines; self.current = current; self.offset = offset; self.settings = settings; self.canSeek = canSeek; self.reduceMotion = reduceMotion
        if rebuild { browsing.follow(); timeout?.cancel(); buildRows(); lastSize = .zero; setNeedsLayout() }
        updateSelectionAppearance()
        if isActive, !rebuild, changed, browsing.phase == .following { centerCurrent(animated:!reduceMotion) }
    }
    private func buildRows() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }; rows = []; labels = []
        contentCategory = traitCollection.preferredContentSizeCategory
        stack.spacing = settings.lyricLineSpacing
        let metrics = UIFontMetrics(forTextStyle:.body)
        for line in lines {
            let row = UIView(); let content = UIStackView(); content.axis = .vertical; content.spacing = 5; content.alignment = .fill
            content.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(content)
            NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:row.leadingAnchor),content.trailingAnchor.constraint(equalTo:row.trailingAnchor),content.topAnchor.constraint(equalTo:row.topAnchor,constant:4),content.bottomAnchor.constraint(equalTo:row.bottomAnchor,constant:-4)])
            let original = UILabel(); original.numberOfLines = 0; original.textAlignment = .center; original.text = line.text
            // Reserve the enlarged font's layout height so highlighting never shifts the scroll geometry.
            original.font = metrics.scaledFont(for:.systemFont(ofSize:settings.lyricFontSize * settings.lyricCurrentLineScale)); content.addArrangedSubview(original)
            var translation: UILabel?
            if let text = line.translation { let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center; label.text = text; label.font = metrics.scaledFont(for:.systemFont(ofSize:max(11,settings.lyricFontSize-4))); content.addArrangedSubview(label); translation = label }
            row.isAccessibilityElement = true; row.accessibilityLabel = [line.text,line.translation].compactMap{$0}.joined(separator:"，")
            row.accessibilityHint = "轻点切回封面；上下滑动以选择歌词"
            stack.addArrangedSubview(row); rows.append(row); labels.append((original,translation))
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); layer.mask?.frame = bounds
        let changed = lastSize != bounds.size
        if changed {
            lastSize = bounds.size
            // Enough room to center even the first and last lines.
            scrollView.contentInset = UIEdgeInsets(top:bounds.height/2,left:0,bottom:bounds.height/2,right:0)
            scrollView.layoutIfNeeded()
            if isActive,browsing.phase == .following { centerCurrent(animated:false) }
        }
        layoutIndicator()
    }
    private func center(_ index: Int, animated: Bool) {
        guard rows.indices.contains(index), bounds.height > 0 else { return }
        scrollView.layoutIfNeeded()
        let rect = rows[index].convert(rows[index].bounds,to:scrollView)
        let y = min(max(-scrollView.contentInset.top,rect.midY-bounds.height/2),max(-scrollView.contentInset.top,scrollView.contentSize.height-bounds.height+scrollView.contentInset.bottom))
        scrollView.setContentOffset(CGPoint(x:0,y:y),animated:animated)
    }
    private func centerCurrent(animated: Bool) { if !rows.isEmpty { center(current ?? 0,animated:animated) } }
    private func nearest() -> Int? {
        let center = scrollView.contentOffset.y + bounds.height/2
        return rows.indices.min { abs(rows[$0].frame.midY-center) < abs(rows[$1].frame.midY-center) }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        timeout?.cancel(); browsing.begin(); browsing.preview(nearest()); updateSelectionAppearance()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if browsing.phase == .dragging { browsing.preview(nearest()); updateSelectionAppearance() }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    private func settle() {
        guard browsing.phase == .dragging else { return }
        browsing.preview(nearest()); browsing.settle()
        if let index = browsing.candidate { center(index,animated:!reduceMotion) }
        updateSelectionAppearance(); armTimeout()
    }
    private func armTimeout() {
        timeout?.cancel(); timeout = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(5)) } catch { return }
            self?.returnToPlayback()
        }
    }
    func returnToPlayback() { timeout?.cancel(); browsing.follow(); updateSelectionAppearance(); centerCurrent(animated:!reduceMotion) }
    private func updateSelectionAppearance() {
        for (index,pair) in labels.enumerated() {
            let active = browsing.phase == .following ? index == current : index == browsing.candidate
            pair.0.textColor = UIColor.white.withAlphaComponent(active ? 0.95 : (browsing.phase == .following ? 0.42 : 0.28))
            pair.1?.textColor = UIColor.white.withAlphaComponent(active ? 0.65 : 0.28)
            let scale = index == current && browsing.phase == .following ? 1 : 1/settings.lyricCurrentLineScale
            pair.0.transform = CGAffineTransform(scaleX:scale,y:scale)
            rows[index].accessibilityTraits = active ? [.staticText,.selected] : .staticText
        }
        indicator.isHidden = browsing.phase == .following
        play.isHidden = browsing.phase == .following; play.isEnabled = canSeek && browsing.phase == .selected
        rule.isHidden = browsing.phase != .dragging
        indicator.backgroundColor = browsing.phase == .selected ? UIColor.white.withAlphaComponent(0.055) : .clear
        if let index = browsing.candidate,lines.indices.contains(index) { time.text = timeLabel(max(0,LyricTiming.adding(lines[index].startMS,offset))) }
        layoutIndicator()
    }
    private func layoutIndicator() {
        let rowHeight = browsing.candidate.flatMap { rows.indices.contains($0) ? rows[$0].bounds.height : nil } ?? 44
        let height = max(44,rowHeight)
        indicator.frame = CGRect(x:8,y:(bounds.height-height)/2,width:max(0,bounds.width-16),height:height)
        rule.frame = CGRect(x:48,y:height/2,width:max(0,indicator.bounds.width-96),height:0.5)
        time.frame = CGRect(x:0,y:0,width:42,height:height)
        play.frame = CGRect(x:bounds.width-48,y:(bounds.height-44)/2,width:44,height:44)
        // The background is below the text; time and play stay above it.
        sendSubviewToBack(indicator); bringSubviewToFront(play)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard !scrollView.isDragging, !scrollView.isDecelerating, browsing.phase != .dragging else { return }
        if browsing.phase == .selected,indicator.frame.contains(gesture.location(in:self)) { confirmSelection() }
        else { invalidate(); onToggle?() }
    }
    @objc func confirmSelection() {
        guard canSeek, let index = browsing.confirmedIndex,lines.indices.contains(index) else { return }
        let line = lines[index]; returnToPlayback(); onConfirm?(line)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !(touch.view is UIControl) }
    func invalidate() { timeout?.cancel(); timeout = nil; browsing.follow() }
}
