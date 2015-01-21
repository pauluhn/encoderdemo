//
//  rtp.h based on RTSPClientConnection
//  Encoder Demo
//
//  Created by Paul Uhn on 1/20/15.
//  Copyright (c) 2015 Paul Uhn. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface rtp : NSObject
- (NSString *)createSession:(NSString *)ip rtp:(int)portRTP rtcp:(int)portRTCP;
- (void)onData:(NSArray *)data time:(double)pts;

// Private methods
- (void) writeHeader:(uint8_t*) packet marker:(BOOL) bMarker time:(double) pts clock:(int)clock;
- (void) sendPacket:(uint8_t*) packet length:(int) cBytes;
@end
