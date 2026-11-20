import XCTest
@testable import Provisioning
import VMCore

final class WindowsFromMicrosoftTests: XCTestCase {
    /// Six entries cut from Microsoft's list of June 2025: ARM64 consumer (Pro and Home, en-us), ARM64 business,
    /// x64 consumer, ARM64 consumer fr-fr, ARM64 consumer sr-latn-rs.
    static let sample = Data(#"""
    <MCT>
      <Catalogs>
        <Catalog version="2.0">
          <PublishedMedia id="" release="">
            <Files>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_en-us.esd</FileName>
                <LanguageCode>en-us</LanguageCode>
                <Language>English (United States)</Language>
                <Edition>Professional</Edition>
                <Architecture>ARM64</Architecture>
                <Size>4527171158</Size>
                <Sha1>c78fd344e845d3b17cb91c40bf4a856459da1b6c</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/37acc189-7f4f-4e07-976c-1cf0a099ec79/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_en-us.esd</FilePath>
                <Key />
                <Architecture_Loc>%ARCH_64%</Architecture_Loc>
                <Edition_Loc>%CLIENT%</Edition_Loc>
                <IsRetailOnly>True</IsRetailOnly>
              </File>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_en-us.esd</FileName>
                <LanguageCode>en-us</LanguageCode>
                <Language>English (United States)</Language>
                <Edition>Core</Edition>
                <Architecture>ARM64</Architecture>
                <Size>4527171158</Size>
                <Sha1>c78fd344e845d3b17cb91c40bf4a856459da1b6c</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/37acc189-7f4f-4e07-976c-1cf0a099ec79/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_en-us.esd</FilePath>
                <Key />
                <IsRetailOnly>True</IsRetailOnly>
              </File>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTBUSINESS_VOL_A64FRE_en-us.esd</FileName>
                <LanguageCode>en-us</LanguageCode>
                <Language>English (United States)</Language>
                <Edition>Enterprise</Edition>
                <Architecture>ARM64</Architecture>
                <Size>4476243990</Size>
                <Sha1>a67698c3b2988dc7fbd38063875a14b5d2e2c9ee</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/f33d02ce-9ad6-4224-90f2-6012845f05f8/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTBUSINESS_VOL_A64FRE_en-us.esd</FilePath>
                <Key />
              </File>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd</FileName>
                <LanguageCode>en-us</LanguageCode>
                <Language>English (United States)</Language>
                <Edition>Professional</Edition>
                <Architecture>x64</Architecture>
                <Size>4680320173</Size>
                <Sha1>8ceab2838f8e90180ac7490e8752157fb05588cb</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/009d9a0d-8e1a-45ce-9540-21377534803e/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd</FilePath>
                <Key />
              </File>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_fr-fr.esd</FileName>
                <LanguageCode>fr-fr</LanguageCode>
                <Language>French (France)</Language>
                <Edition>Professional</Edition>
                <Architecture>ARM64</Architecture>
                <Size>4532016370</Size>
                <Sha1>2942b1baa8943efeca01a1389324049a7aac2ed5</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/3224a028-0b8d-4ae3-8beb-1999f8c15e17/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_fr-fr.esd</FilePath>
                <Key />
              </File>
              <File id="">
                <FileName>26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_sr-latn-rs.esd</FileName>
                <LanguageCode>sr-latn-rs</LanguageCode>
                <Language>Serbian (Latin, Serbia)</Language>
                <Edition>Core</Edition>
                <Architecture>ARM64</Architecture>
                <Size>4409269573</Size>
                <Sha1>32d8ad440484ea115d63e149e2af0cfbccb710d3</Sha1>
                <FilePath>http://dl.delivery.mp.microsoft.com/filestreamingservice/files/99b074e6-7b6a-42ea-9312-10ceb688809a/26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_sr-latn-rs.esd</FilePath>
                <Key />
              </File>
            </Files>
          </PublishedMedia>
        </Catalog>
      </Catalogs>
    </MCT>
    """#.utf8)

    private func images() throws -> [WindowsCatalogue.Image] { try WindowsCatalogue.consumerImages(inProductsXML: Self.sample) }

    func testOnlyARM64ConsumerImagesAreTakenOnePerLanguage() throws {
        let images = try images()
        XCTAssertEqual(images.map(\.languageCode), ["en-us", "fr-fr", "sr-latn-rs"],
                       "x64 and business images are left out; two editions of one file are one image")
        let english = images[0]
        XCTAssertEqual(english.fileName, "26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_A64FRE_en-us.esd")
        XCTAssertEqual(english.bytes, 4527171158)
        XCTAssertEqual(english.sha1, "c78fd344e845d3b17cb91c40bf4a856459da1b6c")
        XCTAssertEqual(english.url.host, "dl.delivery.mp.microsoft.com")
        XCTAssertEqual(english.editions, ["Professional", "Core"])
        XCTAssertEqual(english.build, "26100.4349")
        XCTAssertEqual(english.language, "English (United States)")
    }

    func testLanguageCodesBecomeSetupLocales() throws {
        XCTAssertEqual(try images().map(\.locale), ["en-US", "fr-FR", "sr-Latn-RS"])
        XCTAssertEqual(WindowsCatalogue.locale(fromCode: "es-419"), "es-419")
    }

    func testImagesFromOtherServersAreRefused() throws {
        let text = String(decoding: Self.sample, as: UTF8.self)
        let moved = text.replacingOccurrences(of: "dl.delivery.mp.microsoft.com", with: "downloads.example.com")
        XCTAssertEqual(try WindowsCatalogue.consumerImages(inProductsXML: Data(moved.utf8)).count, 0)
        let lookalike = text.replacingOccurrences(of: "dl.delivery.mp.microsoft.com", with: "evilmicrosoft.com")
        XCTAssertEqual(try WindowsCatalogue.consumerImages(inProductsXML: Data(lookalike.utf8)).count, 0)
    }

    func testDamagedListIsAnError() {
        XCTAssertThrowsError(try WindowsCatalogue.consumerImages(inProductsXML: Data("<MCT><Catalogs>".utf8)))
    }

    func testOptionsPutTheMacLanguageFirstWithBothEditions() throws {
        let english = WindowsFromMicrosoft.options(from: try images(), preferred: ["en-AU", "fr-FR"])
        XCTAssertEqual(english.map(\.id), ["en-us", "en-us-home", "fr-fr", "sr-latn-rs"])
        XCTAssertEqual(english[0].title, "Windows 11 Pro, English (United States)")
        XCTAssertEqual(english[1].title, "Windows 11 Home, English (United States)")
        XCTAssertEqual(english[0].downloadBytes, 4527171158)
        XCTAssertTrue(english[0].detail.contains("26100.4349"))
        let french = WindowsFromMicrosoft.options(from: try images(), preferred: ["fr-CA"])
        XCTAssertEqual(french.map(\.id), ["fr-fr", "en-us", "sr-latn-rs"], "the sample lists only Pro for French")
        let unknown = WindowsFromMicrosoft.options(from: try images(), preferred: ["ja-JP"])
        XCTAssertEqual(unknown.first?.id, "en-us", "a language Microsoft's list lacks falls back to US English")
    }

    func testOptionIDNamesLanguageAndEdition() {
        XCTAssertEqual(WindowsFromMicrosoft.parse(optionID: "en-us").languageCode, "en-us")
        XCTAssertEqual(WindowsFromMicrosoft.parse(optionID: "en-us").edition.name, "Windows 11 Pro")
        XCTAssertEqual(WindowsFromMicrosoft.parse(optionID: "sr-latn-rs-home").languageCode, "sr-latn-rs")
        XCTAssertEqual(WindowsFromMicrosoft.parse(optionID: "sr-latn-rs-home").edition.name, "Windows 11 Home")
        // The answer file has a generic key for each edition offered, or Setup would stop to ask.
        for edition in WindowsFromMicrosoft.editions { XCTAssertNotNil(WindowsUnattendOptions.genericKeys[edition.name]) }
    }

    func testComputerNameFromVMName() {
        XCTAssertEqual(WindowsFromMicrosoft.computerName(from: "Windows 11"), "WINDOWS-11")
        XCTAssertEqual(WindowsFromMicrosoft.computerName(from: "Test Win 11 (DEL ME) again"), "TEST-WIN-11-DEL")
        XCTAssertEqual(WindowsFromMicrosoft.computerName(from: "日本"), "TANDEM-VM")
        let odd = WindowsFromMicrosoft.computerName(from: "a  --  b")
        XCTAssertTrue(WindowsUnattendOptions(computerName: odd, userName: "u", password: "").validate().isEmpty)
    }

    func testDownloadIsCheckedAgainstMicrosoftsSHA1() throws {
        let english = try images()[0]
        let request = DownloadRequest(url: english.url, fileName: english.fileName, checksum: .sha1(english.sha1), expectedBytes: english.bytes)
        XCTAssertEqual(request.checksum, .sha1("c78fd344e845d3b17cb91c40bf4a856459da1b6c"))
        // A file with other contents does not pass.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-sha1-\(UUID().uuidString)")
        try Data("not windows".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(try XCTUnwrap(request.checksum).matches(fileAt: file))
    }

    func testDriverDiscIsFoundLocallyBeforeAnyDownload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-drivers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(WindowsFromMicrosoft.localDriverDisc(named: nil, cache: folder, extraFolders: []))
        try Data().write(to: folder.appendingPathComponent("virtio-win-0.1.302.iso"))
        XCTAssertEqual(WindowsFromMicrosoft.localDriverDisc(named: nil, cache: folder, extraFolders: [])?.lastPathComponent, "virtio-win-0.1.302.iso")
        let named = folder.appendingPathComponent("mine.iso")
        try Data().write(to: named)
        XCTAssertEqual(WindowsFromMicrosoft.localDriverDisc(named: named, cache: folder, extraFolders: [])?.lastPathComponent, "mine.iso")
        XCTAssertEqual(WindowsFromMicrosoft.driverDisc.url.scheme, "https")
    }

    // MARK: Install disc

    static let info = """
    WIM Information:
    ----------------
    Path:           x.esd
    Image Count:    6
    Compression:    LZMS
    Boot Index:     3

    Available Images:
    -----------------
    Index:                  1
    Name:                   Windows Setup Media
    Description:            Windows Setup Media
    Total Bytes:            273754537

    Index:                  2
    Name:                   Microsoft Windows PE (arm64)
    Description:            Microsoft Windows PE (arm64)
    Edition ID:             WindowsPE

    Index:                  3
    Name:                   Microsoft Windows Setup (arm64)
    Edition ID:             WindowsPE

    Index:                  4
    Name:                   Windows 11 Home
    Display Name:           Windows 11 Home
    Edition ID:             Core

    Index:                  5
    Name:                   Windows 11 Home Single Language
    Edition ID:             CoreSingleLanguage

    Index:                  6
    Name:                   Windows 11 Pro
    Edition ID:             Professional
    """

    func testArchiveListingIsReadAndPlanned() throws {
        let images = WindowsImageBuilder.images(fromInfo: Self.info)
        XCTAssertEqual(images.map(\.index), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(images[0].name, "Windows Setup Media")
        XCTAssertNil(images[0].editionID)
        XCTAssertEqual(images[5], .init(index: 6, name: "Windows 11 Pro", editionID: "Professional"))
        let plan = try WindowsImageBuilder.plan(images)
        XCTAssertEqual(plan.media, 1)
        XCTAssertEqual(plan.startup, [2, 3])
        XCTAssertEqual(plan.editions.map(\.name), ["Windows 11 Home", "Windows 11 Home Single Language", "Windows 11 Pro"])
    }

    func testAnArchiveThatIsNotAnInstallImageIsRefused() {
        let onlyEditions = WindowsImageBuilder.images(fromInfo: "Index: 1\nName: Windows 11 Pro\nEdition ID: Professional\n")
        XCTAssertThrowsError(try WindowsImageBuilder.plan(onlyEditions))
        XCTAssertThrowsError(try WindowsImageBuilder.plan([]))
    }

    /// A small disc image with a BIOS-style boot record, as the disc tool writes it.
    private func discWithBootRecord() throws -> URL {
        var disc = [UInt8](repeating: 0, count: 2048 * 24)
        func put(_ bytes: [UInt8], at offset: Int) { disc.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put([1] + Array("CD001".utf8) + [1], at: 16 * 2048)
        put([0] + Array("CD001".utf8) + [1] + Array("EL TORITO SPECIFICATION".utf8), at: 17 * 2048)
        put([23, 0, 0, 0], at: 17 * 2048 + 0x47)
        put([255] + Array("CD001".utf8) + [1], at: 18 * 2048)
        var validation = [UInt8](repeating: 0, count: 32)
        validation[0] = 1; validation[30] = 0x55; validation[31] = 0xAA
        var sum = 0
        for word in 0..<16 { sum = (sum + Int(validation[word * 2]) + Int(validation[word * 2 + 1]) << 8) & 0xFFFF }
        let check = (0x10000 - sum) & 0xFFFF
        validation[28] = UInt8(check & 0xFF); validation[29] = UInt8(check >> 8)
        var entry = [UInt8](repeating: 0, count: 32)
        entry[0] = 0x88; entry[6] = 4; entry[8] = 20
        put(validation + entry, at: 23 * 2048)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-disc-\(UUID().uuidString).iso")
        try Data(disc).write(to: url)
        return url
    }

    func testBootRecordIsMarkedEFIWithTheImagesLength() throws {
        let url = try discWithBootRecord()
        defer { try? FileManager.default.removeItem(at: url) }
        try WindowsImageBuilder.markBootRecordEFI(of: url, bootImageBytes: 1_720_320)
        let disc = [UInt8](try Data(contentsOf: url))
        let catalogue = Array(disc[23 * 2048..<23 * 2048 + 64])
        XCTAssertEqual(catalogue[1], 0xEF, "platform: EFI")
        var sum = 0
        for word in 0..<16 { sum = (sum + Int(catalogue[word * 2]) + Int(catalogue[word * 2 + 1]) << 8) & 0xFFFF }
        XCTAssertEqual(sum, 0, "the validation entry's words still add up to zero")
        XCTAssertEqual(Int(catalogue[38]) | Int(catalogue[39]) << 8, 3360, "1,720,320 bytes in 512-byte sectors")
        XCTAssertEqual(catalogue[40], 20, "where the image is stays as written")
    }

    func testADiscWithoutABootRecordIsAnError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-disc-\(UUID().uuidString).iso")
        try Data(count: 2048 * 24).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try WindowsImageBuilder.markBootRecordEFI(of: url, bootImageBytes: 1024))
    }

    func testProviderSaysWhatIsMissingWithoutWimlib() async {
        let provider = WindowsFromMicrosoft()
        XCTAssertEqual(provider.slot, SystemCatalog.windows)
        XCTAssertEqual(provider.engine, .qemu)
        XCTAssertTrue(provider.allowsEmptyPassword)
        XCTAssertTrue(SystemCatalog.provider(for: SystemCatalog.windows) is WindowsFromMicrosoft)
        XCTAssertTrue(WindowsImageBuilder.wimlibInstallHint.contains("brew install wimlib"))
        if WindowsImageBuilder.wimlib == nil {
            guard case .unavailable(let reason) = provider.availability else { return XCTFail("must be unavailable without wimlib") }
            XCTAssertTrue(reason.contains("brew install wimlib"))
            // Building refuses with the same fix.
            do {
                try await WindowsImageBuilder.build(from: URL(fileURLWithPath: "/nonexistent.esd"), to: URL(fileURLWithPath: "/tmp/x.iso"))
                XCTFail("must throw")
            } catch { XCTAssertTrue(((error as? VMError)?.detail ?? "").contains("brew install wimlib")) }
        } else {
            XCTAssertEqual(provider.availability, .available)
        }
    }
}
