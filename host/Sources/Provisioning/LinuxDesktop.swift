import Foundation
import VMCore

/// The desktop an Ubuntu Desktop VM gets on first start. MATE and Xfce are X11 desktops, which suit
/// Tandem's guest tools (xrandr follows the window size, xclip shares the clipboard); Ubuntu's own
/// GNOME has to be told to use X11, and 26.04's has no X11 session at all.
public enum LinuxDesktop: String, CaseIterable, Codable, Sendable {
    case mate, xfce, gnome

    /// What new Ubuntu Desktop VMs get unless the user picks another.
    public static let standard: LinuxDesktop = .mate

    public var title: String {
        switch self {
        case .mate: return "MATE"
        case .xfce: return "Xfce"
        case .gnome: return "GNOME"
        }
    }

    /// The download option's ID. GNOME keeps the ID it had before there was a choice, so its
    /// templates made by earlier versions stay in use.
    public func optionID(release: String) -> String {
        self == .gnome ? "ubuntu-desktop-\(release)" : "ubuntu-desktop-\(rawValue)-\(release)"
    }

    /// The desktop an option ID names, if it is an Ubuntu Desktop option.
    public static func from(optionID id: String) -> LinuxDesktop? {
        guard id.hasPrefix("ubuntu-desktop-") else { return nil }
        return allCases.first { $0 != .gnome && id.hasPrefix("ubuntu-desktop-\($0.rawValue)-") } ?? .gnome
    }

    /// The one-line description in the list of systems.
    public var note: String {
        switch self {
        case .mate:
            return "The MATE desktop: light, classic menus and panels, with Firefox, a terminal, text editor and file manager. Installed on first start from Ubuntu’s official image: the guest tools connect within a minute, then the desktop takes about 5 to 10 minutes more (it downloads about 800 MB; longer on a slow connection) and the VM restarts into the desktop. Add more apps with apt."
        case .xfce:
            return "The Xfce desktop (Xubuntu’s core set): the lightest of the three, with Firefox, a terminal, text editor and file manager. Installed on first start from Ubuntu’s official image: the guest tools connect within a minute, then the desktop takes about 5 to 10 minutes more (it downloads about 400 MB; longer on a slow connection) and the VM restarts into the desktop. Add more apps with apt."
        case .gnome:
            return "Ubuntu’s GNOME desktop with Firefox and the basic apps (the minimal desktop set), installed on first start from Ubuntu’s official image. The guest tools connect within a minute, then the desktop takes about 5 to 10 minutes more (it downloads about 1 GB; longer on a slow connection) and the VM restarts into the graphical login. Add more apps with the App Center or apt."
        }
    }

    /// Ubuntu packages (besides xclip and xrandr, which every desktop gets).
    var packages: [String] {
        switch self {
        case .gnome:
            return ["ubuntu-desktop-minimal"]
        case .mate:
            // Ubuntu MATE's core set, its sign-in screen, the X server, the network applet and Firefox.
            return ["ubuntu-mate-core", "lightdm", "slick-greeter", "xserver-xorg", "network-manager-gnome", "firefox"]
        case .xfce:
            // Xubuntu's core set (with its default panel layout), its sign-in screen, the X server,
            // the network applet and Firefox.
            return ["xubuntu-core", "lightdm", "lightdm-gtk-greeter", "xserver-xorg", "network-manager-gnome", "firefox"]
        }
    }

    var usesLightDM: Bool { self != .gnome }

    /// Before the packages: LightDM is chosen as the display manager without a question.
    var preInstall: String {
        usesLightDM ? "echo 'lightdm shared/default-x-display-manager select lightdm' | debconf-set-selections; " : ""
    }

    /// After the packages, ending in `&& ` (more commands follow). GNOME: X11 sessions in GDM. LightDM:
    /// the desktop's own X11 session and greeter, and LightDM as the display manager.
    var postInstall: String {
        switch self {
        case .gnome:
            return "mkdir -p /etc/gdm3 && printf '[daemon]\\nWaylandEnable=false\\n' > /etc/gdm3/custom.conf && "
        case .mate:
            // Ubuntu MATE brings its own greeter (Arctica) and settings; Tandem's file comes last, so its
            // session and "no guest sessions" win over theirs.
            return "mkdir -p /etc/lightdm/lightdm.conf.d && "
                + "printf '[Seat:*]\\nuser-session=mate\\nallow-guest=false\\ngreeter-allow-guest=false\\n' > /etc/lightdm/lightdm.conf.d/99-tandem-session.conf && "
                + Self.lightDMCommon
        case .xfce:
            // Xubuntu's session carries its panel layout; without it Xfce's panel asks on first start.
            return "{ s=xfce; [ -f /usr/share/xsessions/xubuntu.desktop ] && s=xubuntu; true; } && mkdir -p /etc/lightdm/lightdm.conf.d && "
                + "printf '[Seat:*]\\nuser-session=%s\\nallow-guest=false\\ngreeter-allow-guest=false\\n' \"$s\" > /etc/lightdm/lightdm.conf.d/99-tandem-session.conf && "
                + Self.lightDMCommon
        }
    }

    /// LightDM as the display manager; no offer to move to the next Ubuntu release (the user chose
    /// this one); the guest tools disc kept off the desktop (the tools update themselves).
    static let lightDMCommon = "echo /usr/sbin/lightdm > /etc/X11/default-display-manager && "
        + "{ [ -f /etc/update-manager/release-upgrades ] && sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades; true; } && "
        + "printf 'ENV{ID_FS_LABEL}==\"\(GuestTools.linuxVolumeName)\", ENV{UDISKS_IGNORE}=\"1\"\\n' > /etc/udev/rules.d/99-tandem-hide-tools-disc.rules && "
}
