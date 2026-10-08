package sfu

import (
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

// Sender reports and lip sync.
//
// Audio and video travel as separate RTP streams, each with timestamps on
// its own clock. A sender report maps one stream's timestamps to wall-clock
// time ("RTP timestamp X was captured at NTP time Y"); with one for each
// stream, the receiver knows which audio goes with which video frame and
// delays whichever is ahead.
//
// The SFU passes RTP timestamps through untouched, so a publisher's sender
// report stays true for the forwarded stream. Only the SSRC, which differs
// on every subscriber's connection, has to be rewritten. (Stage 4's layer
// switching will rewrite timestamps too, and must then shift the reports by
// the same offset.)

// readSenderReports reads RTCP about a published track until the track ends
// and passes on the publisher's sender reports. Reading also lets the
// receiver-report interceptor see them, which it needs to report round-trip
// time back to the publisher.
func readSenderReports(receiver *webrtc.RTPReceiver, remote *webrtc.TrackRemote, forward func(*rtcp.SenderReport)) {
	for {
		packets, _, err := receiver.ReadRTCP()
		if err != nil {
			return
		}
		for _, p := range packets {
			if sr, ok := p.(*rtcp.SenderReport); ok && sr.SSRC == uint32(remote.SSRC()) {
				forward(sr)
			}
		}
	}
}

// senderReportFor returns sr as it should reach a subscriber through sender:
// the same clock mapping and counts, under the sender's SSRC.
func senderReportFor(sender *webrtc.RTPSender, sr *rtcp.SenderReport) (*rtcp.SenderReport, bool) {
	encodings := sender.GetParameters().Encodings
	if len(encodings) == 0 || encodings[0].SSRC == 0 {
		return nil, false
	}
	return &rtcp.SenderReport{
		SSRC:        uint32(encodings[0].SSRC),
		NTPTime:     sr.NTPTime,
		RTPTime:     sr.RTPTime,
		PacketCount: sr.PacketCount,
		OctetCount:  sr.OctetCount,
	}, true
}
