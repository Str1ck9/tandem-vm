import Foundation

/// How large Windows' interface should be when its screen has more pixels than the Mac window has points
/// (a Retina-sized boot, for example 3024 × 1740 in a window of 1512 × 870 points). Windows then comes up at
/// 100% and everything is half the size it should be. The scale that gives the interface the size it has in
/// a window of that many points is the ratio of the two, rounded to a step Windows offers.
public enum GuestDisplayScale {
    /// The scales Windows' display settings offer, in percent.
    public static let steps: [Int] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]

    /// Below this ratio of pixels to points the guest's own scale is left alone.
    public static let threshold = 1.2

    /// The scale to give Windows so its interface is as large on the Mac as it would be at 100% in a window
    /// of `viewWidthPoints` points. 100 when the picture is not noticeably larger than the window.
    public static func recommendedPercent(guestWidth: Int, viewWidthPoints: Double) -> Int {
        guard guestWidth > 0, viewWidthPoints > 0 else { return 100 }
        let ratio = Double(guestWidth) / viewWidthPoints
        guard ratio >= threshold else { return 100 }
        let wanted = ratio * 100
        // The nearest step Windows offers.
        return steps.min { abs(Double($0) - wanted) < abs(Double($1) - wanted) } ?? 100
    }

    /// The scale to ask Windows for now, or nil when nothing should change: the setting is off, or the
    /// window's size is not known yet.
    public static func target(guestWidth: Int, viewWidthPoints: Double?, enabled: Bool) -> Int? {
        guard enabled, let viewWidthPoints, guestWidth > 0 else { return nil }
        return recommendedPercent(guestWidth: guestWidth, viewWidthPoints: viewWidthPoints)
    }

    /// The guest screen size for a window of `points`: even numbers (the display device wants them), within
    /// what it accepts. `factor` is the pixels per point (1, or the screen's backing scale for Retina resolution).
    public static func guestPixels(forPoints width: Double, _ height: Double, factor: Double) -> (width: Int, height: Int) {
        let w = Int((width * factor).rounded(.down)) & ~1, h = Int((height * factor).rounded(.down)) & ~1
        return (min(max(w, 800), 5120), min(max(h, 600), 2880))
    }
}
