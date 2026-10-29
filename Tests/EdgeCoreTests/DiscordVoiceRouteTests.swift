import Foundation
import Testing
@testable import EdgeCore

@Suite struct DiscordVoiceRouteTests {
  @Test func parsesDeviceListAndSelection() {
    let route = DiscordVoiceRoute().applying(["device_id": "usb", "available_devices": [["id":"default","name":"Default"],["id":"usb","name":"USB microphone"]]])
    #expect(route.selectedID == "usb")
    #expect(route.selected?.name == "USB microphone")
  }
  @Test func partialEventsPreserveDevices() {
    let original = DiscordVoiceRoute(selectedID:"usb", devices:[DiscordVoiceDevice(id:"usb", name:"Mic")])
    let updated = original.applying(["device_id":"default"])
    #expect(updated.selectedID == "default")
    #expect(updated.devices == original.devices)
    #expect(updated.applying(["volume":42]) == updated)
  }
  @Test func missingSelectionNeverPretendsToBeDefault() {
    let route = DiscordVoiceRoute(selectedID: "usb", devices: [])
    #expect(route.applying(["device_id": NSNull()]).selectedID == nil)
    #expect(route.applying(["device_id": ""]).selectedID == nil)
    #expect(route.applying([:]).selectedID == "usb")
  }
  @Test func unpluggedAndMalformedDevices() {
    let original = DiscordVoiceRoute(selectedID:"usb", devices:[DiscordVoiceDevice(id:"usb", name:"Mic")])
    #expect(original.applying(["available_devices": [[String:String]]()]).devices.isEmpty)
    let route = original.applying(["available_devices":[["id":"x","name":"A"],["id":"x","name":"B"],["id":"","name":"Invalid"],["id":"no-name"]]])
    #expect(route.devices == [DiscordVoiceDevice(id:"x",name:"A")])
    #expect(route.selected == nil)
  }
}
