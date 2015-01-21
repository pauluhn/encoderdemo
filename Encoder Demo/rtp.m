//
//  rtp.m based on RTSPClientConnection
//  Encoder Demo
//
//  Created by Paul Uhn on 1/20/15.
//  Copyright (c) 2015 Paul Uhn. All rights reserved.
//

#import "rtp.h"
#import "arpa/inet.h"

void tonet_short(uint8_t* p, unsigned short s)
{
    p[0] = (s >> 8) & 0xff;
    p[1] = s & 0xff;
}
void tonet_long(uint8_t* p, unsigned long l)
{
    p[0] = (l >> 24) & 0xff;
    p[1] = (l >> 16) & 0xff;
    p[2] = (l >> 8) & 0xff;
    p[3] = l & 0xff;
}

@interface rtp ()
{
    CFDataRef _addrRTP;
    CFSocketRef _sRTP;
    CFDataRef _addrRTCP;
    CFSocketRef _sRTCP;
    NSString* _session;
    long _packets;
    long _bytesSent;
    long _ssrc;
    
    // time mapping using NTP
    uint64_t _ntpBase;
    uint64_t _rtpBase;
    double _ptsBase;
    
    // RTCP stats
    long _packetsReported;
    long _bytesReported;
    NSDate* _sentRTCP;

    // reader reports
    CFSocketRef _recvRTCP;
    CFRunLoopSourceRef _rlsRTCP;
}
@end

@implementation rtp

- (NSString *)createSession:(NSString *)ip rtp:(int)portRTP rtcp:(int)portRTCP
{
    // !! most basic possible for initial testing
    @synchronized(self)
    {
        struct sockaddr_in paddr;
        inet_aton([ip UTF8String], &paddr.sin_addr);
        paddr.sin_family = AF_INET;
        
        paddr.sin_port = htons(portRTP);
        _addrRTP = CFDataCreate(nil, (uint8_t*) &paddr, sizeof(struct sockaddr_in));
        _sRTP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil);
        
        paddr.sin_port = htons(portRTCP);
        _addrRTCP = CFDataCreate(nil, (uint8_t*) &paddr, sizeof(struct sockaddr_in));
        _sRTCP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, 0, nil, nil);
        
        // reader reports received here
        CFSocketContext info;
        memset(&info, 0, sizeof(info));
        info.info = (void*)CFBridgingRetain(self);
        _recvRTCP = CFSocketCreate(nil, PF_INET, SOCK_DGRAM, IPPROTO_UDP, kCFSocketDataCallBack, NULL, &info);
        
        struct sockaddr_in addr;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_family = AF_INET;
        addr.sin_port = htons(6971);
        CFDataRef dataAddr = CFDataCreate(nil, (const uint8_t*)&addr, sizeof(addr));
        CFSocketSetAddress(_recvRTCP, dataAddr);
        CFRelease(dataAddr);
        
        _rlsRTCP = CFSocketCreateRunLoopSource(nil, _recvRTCP, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), _rlsRTCP, kCFRunLoopCommonModes);
        
        // flag that setup is valid
        long sessionid = random();
        _session = [NSString stringWithFormat:@"%ld", sessionid];
        _ssrc = random();
        _packets = 0;
        _bytesSent = 0;
        _rtpBase = 0;
        
        _sentRTCP = nil;
        _packetsReported = 0;
        _bytesReported = 0;
    }
    return _session;
}

- (void)onData:(NSArray *)data time:(double)pts
{
    const int max_packet_size = 1200;
    const int rtp_header_size = 12;
    const int max_single_packet = max_packet_size - rtp_header_size;
    const int max_fragment_packet = max_single_packet - 2;
    unsigned char packet[max_packet_size];
    const int clock = 90000;
    
    int nNALUs = (int)[data count];
    for (int i = 0; i < nNALUs; i++)
    {
        NSData* nalu = [data objectAtIndex:i];
        int cBytes = (int)[nalu length];
        BOOL bLast = (i == nNALUs-1);
        
        const unsigned char* pSource = (unsigned char*)[nalu bytes];
        
        if (cBytes < max_single_packet)
        {
            [self writeHeader:packet marker:bLast time:pts clock:clock];
            memcpy(packet + rtp_header_size, [nalu bytes], cBytes);
            [self sendPacket:packet length:(cBytes + rtp_header_size)];
        }
        else
        {
            unsigned char NALU_Header = pSource[0];
            pSource += 1;
            cBytes -= 1;
            BOOL bStart = YES;
            
            while (cBytes)
            {
                int cThis = (cBytes < max_fragment_packet)? cBytes : max_fragment_packet;
                BOOL bEnd = (cThis == cBytes);
                [self writeHeader:packet marker:(bLast && bEnd) time:pts clock:clock];
                unsigned char* pDest = packet + rtp_header_size;
                
                pDest[0] = (NALU_Header & 0xe0) + 28;   // FU_A type
                unsigned char fu_header = (NALU_Header & 0x1f);
                if (bStart)
                {
                    fu_header |= 0x80;
                    bStart = false;
                }
                else if (bEnd)
                {
                    fu_header |= 0x40;
                }
                pDest[1] = fu_header;
                pDest += 2;
                memcpy(pDest, pSource, cThis);
                pDest += cThis;
                [self sendPacket:packet length:(int)(pDest - packet)];
                
                pSource += cThis;
                cBytes -= cThis;
            }
        }
    }
}

- (void)dealloc
{
    @synchronized(self)
    {
        if (_sRTP)
        {
            CFSocketInvalidate(_sRTP);
            _sRTP = nil;
        }
        if (_sRTCP)
        {
            CFSocketInvalidate(_sRTCP);
            _sRTCP = nil;
        }
        if (_recvRTCP)
        {
            CFSocketInvalidate(_recvRTCP);
            _recvRTCP = nil;
        }
        _session = nil;
    }
}

- (void) writeHeader:(uint8_t*) packet marker:(BOOL) bMarker time:(double) pts clock:(int)clock
{
    packet[0] = 0x80;   // v= 2
    if (bMarker)
    {
        packet[1] = 96 | 0x80;
    }
    else
    {
        packet[1] = 96;
    }
    unsigned short seq = _packets & 0xffff;
    tonet_short(packet+2, seq);
    
    // map time
    while (_rtpBase == 0)
    {
        _rtpBase = random();
        _ptsBase = pts;
        NSDate* now = [NSDate date];
        // ntp is based on 1900. There's a known fixed offset from 1900 to 1970.
        NSDate* ref = [NSDate dateWithTimeIntervalSince1970:-2208988800L];
        double interval = [now timeIntervalSinceDate:ref];
        _ntpBase = (uint64_t)(interval * (1LL << 32));
    }
    pts -= _ptsBase;
    uint64_t rtp = (uint64_t)(pts * clock);
    rtp += _rtpBase;
    tonet_long(packet + 4, rtp);
    tonet_long(packet + 8, _ssrc);
}

- (void) sendPacket:(uint8_t*) packet length:(int) cBytes
{
    @synchronized(self)
    {
        if (_sRTP)
        {
            CFDataRef data = CFDataCreate(nil, packet, cBytes);
            CFSocketSendData(_sRTP, _addrRTP, data, 0);
            CFRelease(data);
        }
        _packets++;
        _bytesSent += cBytes;
        
        // RTCP packets
        NSDate* now = [NSDate date];
        if ((_sentRTCP == nil) || ([now timeIntervalSinceDate:_sentRTCP] >= 1))
        {
            uint8_t buf[7 * sizeof(uint32_t)];
            buf[0] = 0x80;
            buf[1] = 200;   // type == SR
            tonet_short(buf+2, 6);  // length (count of uint32_t minus 1)
            tonet_long(buf+4, _ssrc);
            tonet_long(buf+8, (_ntpBase >> 32));
            tonet_long(buf+12, _ntpBase);
            tonet_long(buf+16, _rtpBase);
            tonet_long(buf+20, (_packets - _packetsReported));
            tonet_long(buf+24, (_bytesSent - _bytesReported));
            int lenRTCP = 28;
            if (_sRTCP)
            {
                CFDataRef dataRTCP = CFDataCreate(nil, buf, lenRTCP);
                CFSocketSendData(_sRTCP, _addrRTCP, dataRTCP, lenRTCP);
                CFRelease(dataRTCP);
            }
            
            _sentRTCP = now;
            _packetsReported = _packets;
            _bytesReported = _bytesSent;
        }
    }
}

@end
