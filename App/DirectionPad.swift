// SPDX-License-Identifier: AGPL-3.0-only
//
// Direction pad for the CarPlay home screen, for when the dashboard has no touch screen.
//
// CarPlay's non-touch input model is a knob, not a d-pad (see CarPlayInfo.knobDescriptor): the
// protocol carries a relative wheel for focus movement, one select button, AC Home and AC Back. It
// has no left/right focus axis, so ◀ and ▶ here are wired to Back and Home — real, working actions —
// instead of pretending to move sideways and doing nothing.
//
//   ▲ wheel -1 (previous)    ▼ wheel +1 (next)
//   ● select                 ◀ back                 ▶ home
//
// Holding ▲ or ▼ repeats, which is what a list of songs or a long menu needs.

import UIKit

final class DirectionPad: UIView {
    /// A key was pressed. `repeated` is true for the automatic repeats of a held ▲/▼.
    var onPress: ((CarPlayControl, _ repeated: Bool) -> Void)?

    private let up = DirectionPad.makeKey("chevron.up", label: "上一项")
    private let down = DirectionPad.makeKey("chevron.down", label: "下一项")
    private let left = DirectionPad.makeKey("chevron.backward", label: "返回")
    private let right = DirectionPad.makeKey("chevron.forward", label: "主页")
    private let select = DirectionPad.makeKey("smallcircle.filled.circle", label: "选择")

    private var repeatTimer: Timer?
    private var repeatingControl: CarPlayControl?
    private var repeatCount = 0

    /// Delay before a held key starts repeating, and the interval between repeats.
    private let initialDelay: TimeInterval = 0.45
    private let repeatInterval: TimeInterval = 0.15

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        // Cross layout: three rows, the middle row holds ◀ ● ▶.
        let topRow = row([spacer(), up, spacer()])
        let middleRow = row([left, select, right])
        let bottomRow = row([spacer(), down, spacer()])
        let grid = UIStackView(arrangedSubviews: [topRow, middleRow, bottomRow])
        grid.axis = .vertical
        grid.spacing = 8
        grid.alignment = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])

        bind(up, .knobPrevious, repeats: true)
        bind(down, .knobNext, repeats: true)
        bind(select, .select, repeats: false)
        bind(left, .back, repeats: false)
        bind(right, .home, repeats: false)
    }

    private func row(_ views: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.distribution = .fill
        return stack
    }

    private func spacer() -> UIView {
        // Keeps ▲/▼ centred over ● in the cross layout.
        let view = UIView()
        view.widthAnchor.constraint(equalToConstant: 64).isActive = true
        view.heightAnchor.constraint(equalToConstant: 64).isActive = true
        return view
    }

    private func bind(_ button: UIButton, _ control: CarPlayControl, repeats: Bool) {
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onPress?(control, false)
            if repeats { self.beginRepeating(control) }
        }, for: .touchDown)

        let finish: UIActionHandler = { [weak self] _ in self?.endRepeating() }
        button.addAction(UIAction(handler: finish), for: .touchUpInside)
        button.addAction(UIAction(handler: finish), for: .touchUpOutside)
        button.addAction(UIAction(handler: finish), for: .touchCancel)
    }

    private func beginRepeating(_ control: CarPlayControl) {
        endRepeating()
        repeatingControl = control
        repeatCount = 0
        // A single tap is not a repeat: the first repeat waits out the initial delay.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: initialDelay, repeats: false) { [weak self] _ in
            self?.startFastRepeat()
        }
    }

    private func startFastRepeat() {
        guard let control = repeatingControl else { return }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            guard let self, let control = self.repeatingControl else { return }
            self.repeatCount += 1
            UISelectionFeedbackGenerator().selectionChanged()
            self.onPress?(control, true)
        }
    }

    private func endRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingControl = nil
        repeatCount = 0
    }

    deinit { repeatTimer?.invalidate() }

    private static func makeKey(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.9)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let button = UIButton(configuration: configuration, primaryAction: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 64),
            button.heightAnchor.constraint(equalToConstant: 64)
        ])
        button.accessibilityLabel = label
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        return button
    }
}