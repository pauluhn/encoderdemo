//
//  rtp_audio.m based on RTSPClientConnection, AACADTSPacketizer.java
//  Encoder Demo, libstreaming
//
//  Created by Paul Uhn on 1/20/15.
//  Copyright (c) 2015 Paul Uhn. All rights reserved.
//

#import "rtp_audio.h"

@implementation rtp_audio

- (void)onData:(NSArray *)data time:(double)pts
{
    const int max_packet_size = 512;
    const int rtp_header_size = 12;
    const int au_header_size = 4;
    unsigned char packet[max_packet_size];
    const int clock = 44100;

    NSData *rawAAC = data[0];
    int cBytes = (int)[rawAAC length];
    
    [self writeHeader:packet marker:NO time:pts clock:clock];
    [self writeAUHeader:packet rtphl:rtp_header_size frameLength:cBytes];
    memcpy(packet + rtp_header_size + au_header_size, [rawAAC bytes], cBytes);
    [self sendPacket:packet length:(cBytes + rtp_header_size + au_header_size)];
}

- (void)writeAUHeader:(uint8_t *)buffer rtphl:(int)rtphl frameLength:(int)frameLength
{
    // AU-headers-length field: contains the size in bits of a AU-header
    // 13+3 = 16 bits -> 13bits for AU-size and 3bits for AU-Index / AU-Index-delta
    // 13 bits will be enough because ADTS uses 13 bits for frame length
    buffer[rtphl] = 0;
    buffer[rtphl+1] = 0x10;
    
    // AU-size
    buffer[rtphl+2] = (frameLength>>5);
    buffer[rtphl+3] = (frameLength<<3);
    
    // AU-Index
    buffer[rtphl+3] &= 0xF8;
    buffer[rtphl+3] |= 0x00;
}

@end
