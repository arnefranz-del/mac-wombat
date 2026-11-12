import Testing
import Foundation
@testable import WombatCore

struct InterfaceAndFormatterTests {
    @Test func testOnlyPhysicalEthernetAndWifiAreSelected() {
        for name in ["en0", "en1", "en12"] {
            for kind in [TransportKind.wifi, .ethernet] {
                #expect(InterfacePolicy.includes(InterfaceDescriptor(name: name, displayName: name, kind: kind)))
            }
        }
        for name in ["lo0", "utun0", "utun8", "awdl0", "llw0", "bridge0", "bond0", "vlan0",
                     "vmnet1", "vmenet0", "tap0", "tun0", "ap1", "gif0", "stf0", "en", "enX"] {
            // Reject overlay names even if a driver reports Ethernet as its type.
            #expect(!(InterfacePolicy.includes(InterfaceDescriptor(name: name, displayName: name, kind: .ethernet))))
        }
        #expect(!(InterfacePolicy.includes(InterfaceDescriptor(name: "en0", displayName: "Other", kind: .other))))
    }

    @Test func testDecimalUnitsAndGermanFormatting() {
        let de = Locale(identifier: "de_DE")
        #expect((RateFormatter.format(0, locale: de).text) == ("0 B/s"))
        #expect((RateFormatter.format(820_000, locale: de).text) == ("820 KB/s"))
        #expect((RateFormatter.format(12_400_000, locale: de).text) == ("12,4 MB/s"))
        #expect((RateFormatter.format(1_500_000_000, locale: de).text) == ("1,5 GB/s"))
        #expect((RateFormatter.format(1_000, locale: de).text) == ("1,0 KB/s"))
        #expect((RateFormatter.format(999_600, locale: de).text) == ("1,0 MB/s"))
    }

    @Test func testInvalidRatesHaveSafeOutput() {
        for value in [Double.nan, .infinity, -.infinity, -20] {
            #expect((RateFormatter.format(value, locale: Locale(identifier: "en_US")).text) == ("0 B/s"))
        }
    }
}
