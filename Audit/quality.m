#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <math.h>
#include <stdio.h>
static double quality(CVPixelBufferRef pred,
                      CVPixelBufferRef prev,
                      CVPixelBufferRef next,
                      CVPixelBufferRef reference,
                      double *hold,
                      double *blend,
                      double *artifact) {
    CVPixelBufferRef frames[] = {pred, prev, next, reference};
    BOOL ok = YES;
    for (int i = 0; i < 4; i++)
        if (CVPixelBufferLockBaseAddress(frames[i], kCVPixelBufferLock_ReadOnly) !=
            kCVReturnSuccess) {
            ok = NO;
            break;
        }
    if (!ok)
        return NAN;
    int w = (int)CVPixelBufferGetWidthOfPlane(pred, 0),
        h = (int)CVPixelBufferGetHeightOfPlane(pred, 0);
    const uint8_t *a[4];
    size_t strides[4];
    for (int i = 0; i < 4; i++) {
        a[i] = CVPixelBufferGetBaseAddressOfPlane(frames[i], 0);
        strides[i] = CVPixelBufferGetBytesPerRowOfPlane(frames[i], 0);
    }
    double fg = 0, hd = 0, ln = 0, bad = 0, n = 0;
    for (int y = 0; y < h; y += 8)
        for (int x = 0; x < w; x += 8) {
            int values[4];
            for (int i = 0; i < 4; i++)
                values[i] = a[i][y * strides[i] + x];
            double e = values[0] - values[3], eHold = values[1] - values[3],
                   eBlend = (values[1] + values[2]) / 2. - values[3];
            fg += e * e;
            hd += eHold * eHold;
            ln += eBlend * eBlend;
            if (fabs(e) > 64)
                bad++;
            n++;
        }
    for (int i = 0; i < 4; i++)
        CVPixelBufferUnlockBaseAddress(frames[i], kCVPixelBufferLock_ReadOnly);
    *hold = 10 * log10(255. * 255. / MAX(1e-7, hd / n));
    *blend = 10 * log10(255. * 255. / MAX(1e-7, ln / n));
    *artifact = bad / n * 100;
    return 10 * log10(255. * 255. / MAX(1e-7, fg / n));
}
static double median(NSArray<NSNumber *> *array) {
    if (!array.count)
        return NAN;
    NSArray *a = [array sortedArrayUsingSelector:@selector(compare:)];
    return [a[a.count / 2] doubleValue];
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *base = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Application Support/MetalCadence"];
        NSURL *url = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"replay.mp4"]];
        NSError *e = nil;
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&e];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!reader || !track) {
            NSLog(@"Cannot read video %@", e);
            return 2;
        }
        NSDictionary *opts = @{
            (id)
            kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        };
        AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
                                                                         outputSettings:opts];
        [reader addOutput:out];
        if (![reader startReading]) {
            NSLog(@"Reader failed %@", reader.error);
            return 3;
        }
        CVPixelBufferPoolRef pool = NULL;
        VTLowLatencyFrameInterpolationConfiguration *cfg =
            [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:1920
                                                                        frameHeight:1080
                                                         numberOfInterpolatedFrames:1];
        VTFrameProcessor *processor = [VTFrameProcessor new];
        if (![processor startSessionWithConfiguration:cfg error:&e]) {
            NSLog(@"Session failed %@", e);
            return 4;
        }
        if (CVPixelBufferPoolCreate(NULL,
                                    NULL,
                                    (__bridge CFDictionaryRef)cfg.destinationPixelBufferAttributes,
                                    &pool) != kCVReturnSuccess)
            return 5;
        NSString *folder = [base stringByAppendingPathComponent:@"audit"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *csv = [folder stringByAppendingPathComponent:@"quality.csv"];
        [@"" writeToFile:csv atomically:YES encoding:NSUTF8StringEncoding error:nil];
        FILE *fp = fopen(csv.fileSystemRepresentation, "w");
        fprintf(fp,
                "pair,generated_psnr_db,held_psnr_db,linear_blend_psnr_db,large_error_percent,"
                "processing_ms\n");
        NSMutableArray *fgScores = [NSMutableArray new], *holdScores = [NSMutableArray new],
                       *blendScores = [NSMutableArray new], *durations = [NSMutableArray new];
        int fgBetter = 0, blBetter = 0, bad = 0;
        CMSampleBufferRef prev = [out copyNextSampleBuffer];
        int maxPairs = argc > 1 ? MAX(10, MIN(800, atoi(argv[1]))) : 240;
        for (int i = 0; i < maxPairs && prev; i++) {
            @autoreleasepool {
                CMSampleBufferRef odd = [out copyNextSampleBuffer],
                                  next = [out copyNextSampleBuffer];
                if (!odd || !next) {
                    if (odd)
                        CFRelease(odd);
                    if (next)
                        CFRelease(next);
                    break;
                }
                CVPixelBufferRef a = CMSampleBufferGetImageBuffer(prev),
                                 b = CMSampleBufferGetImageBuffer(next),
                                 reference = CMSampleBufferGetImageBuffer(odd), dest = NULL;
                if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &dest) != kCVReturnSuccess) {
                    CFRelease(odd);
                    CFRelease(next);
                    break;
                }
                VTFrameProcessorFrame *af = [[VTFrameProcessorFrame alloc]
                                                 initWithBuffer:a
                                          presentationTimeStamp:CMTimeMake(i * 2, 60)],
                                      *bf = [[VTFrameProcessorFrame alloc]
                                                 initWithBuffer:b
                                          presentationTimeStamp:CMTimeMake(i * 2 + 2, 60)],
                                      *mf = [[VTFrameProcessorFrame alloc]
                                                 initWithBuffer:dest
                                          presentationTimeStamp:CMTimeMake(i * 2 + 1, 60)];
                VTLowLatencyFrameInterpolationParameters *params =
                    [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:bf
                                                                            previousFrame:af
                                                                       interpolationPhase:@[ @0.5 ]
                                                                        destinationFrames:@[ mf ]];
                CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
                BOOL success = [processor processWithParameters:params error:&e];
                double ms = (CFAbsoluteTimeGetCurrent() - t) * 1000;
                if (success) {
                    double h, l, art;
                    double f = quality(dest, a, b, reference, &h, &l, &art);
                    if (isfinite(f)) {
                        [fgScores addObject:@(f)];
                        [holdScores addObject:@(h)];
                        [blendScores addObject:@(l)];
                        [durations addObject:@(ms)];
                        if (f > h)
                            fgBetter++;
                        if (f > l)
                            blBetter++;
                        if (art > 10)
                            bad++;
                        fprintf(fp, "%d,%.5f,%.5f,%.5f,%.4f,%.4f\n", i, f, h, l, art, ms);
                    }
                } else
                    NSLog(@"VideoToolbox fail pair %d %@", i, e);
                CVPixelBufferRelease(dest);
                CFRelease(prev);
                CFRelease(odd);
                prev = next;
            }
        }
        if (prev)
            CFRelease(prev);
        fclose(fp);
        [processor endSession];
        CVPixelBufferPoolRelease(pool);
        printf("QUALITY pairs=%lu FG_PSNR_median=%.2f held_PSNR_median=%.2f blend_PSNR_median=%.2f "
               "FG_wins_vs_hold=%d FG_wins_vs_blend=%d large_error_pairs=%d VT_median_ms=%.2f "
               "CSV=%s\n",
               (unsigned long)fgScores.count,
               median(fgScores),
               median(holdScores),
               median(blendScores),
               fgBetter,
               blBetter,
               bad,
               median(durations),
               csv.UTF8String);
        return fgScores.count > 10 ? 0 : 6;
    }
}
