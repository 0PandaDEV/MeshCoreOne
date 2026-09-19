@testable import MC1
import Testing

@Suite("RadioCLIPassthrough")
struct RadioCLIPassthroughTests {
  @Test
  func `passthrough get cad and set wifi.ssid, not wifi_ssid or _cad`() {
    #expect(RadioCLIPassthrough.shouldSend("get cad"))
    #expect(RadioCLIPassthrough.shouldSend("set cad on"))
    #expect(RadioCLIPassthrough.shouldSend("set wifi.clear"))
    #expect(RadioCLIPassthrough.shouldSend("set wifi.ssid lab"))
    #expect(!RadioCLIPassthrough.shouldSend("set wifi_ssid lab"))
    #expect(!RadioCLIPassthrough.shouldSend("get _cad"))
    #expect(!RadioCLIPassthrough.shouldSend("get name"))
    #expect(!RadioCLIPassthrough.shouldSend("reboot"))
    #expect(!RadioCLIPassthrough.shouldSend("poweroff"))
    #expect(!RadioCLIPassthrough.shouldSend("shutdown"))
    #expect(!RadioCLIPassthrough.shouldSend("logout"))
    #expect(!RadioCLIPassthrough.shouldSend("get wifi.pwd"))
    #expect(RadioCLIPassthrough.shouldSend("set wifi.pwd secret"))
    #expect(RadioCLIPassthrough.shouldSend("get af"))
    #expect(RadioCLIPassthrough.shouldSend("get dutycycle"))
    #expect(RadioCLIPassthrough.shouldSend("get radio.rxgain"))
    #expect(RadioCLIPassthrough.shouldSend("get rxdelay"))
    #expect(RadioCLIPassthrough.shouldSend("blarg"))
  }
}
