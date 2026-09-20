import Lightray
import Testing

@Test func packageLoads() { #expect(Configuration().maxDatagramSize == 1200) }
