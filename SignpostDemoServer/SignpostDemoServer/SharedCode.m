//
//  SharedCode.m
//  SignpostDemoServer
//
//  Created by Sebastian Eide on 08/05/2012.
//  Copyright (c) 2012 Kle.io. All rights reserved.
//

#import "SharedCode.h"
#import "GCDAsyncSocket.h"
#import "GCDAsyncUdpSocket.h"

@implementation SharedCode

@synthesize hostname = _hostname;

////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Setup
////////////////////////////////////////////////////////////////////////////////////////////////////

- (id)init 
{
  self = [super init];
  if (self)
  {
    dataPayload = nil;
    startTimeBandwidth = nil;
    startTimeLatency = nil;
    latency = 0.0;
    jitterMeasurements = [[NSMutableDictionary alloc] init];
    jitterCache = [[NSMutableDictionary alloc] init];
    jitterCalcQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
  }
  return self;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Latency related functionality
////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)startLatencyMeasurement {
  startTimeLatency = [NSDate date];
}

- (void)concludeLatencyMeasurement {
  latency = ([startTimeLatency timeIntervalSinceNow] * -1000.0)/2.0; // We divide by two to get latency, rather than RTT.
}

- (double)latency 
{
  return latency;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Bandwidth related functionality
////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)startBandwidthMeasurement
{
  startTimeBandwidth = [NSDate date];
}

- (NSInteger) getBandwidthInMegabitsPerSecond
{
  double transmissionTime = [startTimeBandwidth timeIntervalSinceNow] * (-1000.0) - (2 * latency); // in ms
  double numPerSecond = (1 / transmissionTime) * 1000;
  double bytesPerSecond = numPerSecond * DATASIZE;
  NSUInteger bytesPerMegabit = 131072.0;
  double mbitPerSecond = bytesPerSecond / bytesPerMegabit;        
  return mbitPerSecond;
}


////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Encoding and decoding data for the wire
////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSData *) dataPayload 
{
  if (dataPayload == nil)
  {
    // Set the data values
    NSMutableString * tempString = [NSMutableString stringWithCapacity:DATASIZE];
    for (int i = 0; i < (DATASIZE / 10); i++) {
      [tempString appendString:@"abcdefghij"];
    }
    dataPayload = [tempString dataUsingEncoding:NSUTF8StringEncoding];  
  }
  return dataPayload;
}

+ (NSData *) intToData:(NSInteger)integerValue 
{
  NSString *stringValue = FORMAT(@"%i\r\n", integerValue);
  return [stringValue dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSInteger) dataToInt:(NSData *)data 
{
  NSString *stringData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [stringData integerValue];
}

+ (NSData *) payloadForString:(NSString *)stringVal
{
  return [stringVal dataUsingEncoding:NSUTF8StringEncoding];  
}

// This method takes a host and a port. The host and port serve to provide 
// a unique name for the other party to identity packages coming from this host,
// so that multiple jitter measurements can be done simultaneously.
- (NSData *) jitterPayloadContainingJitter:(NSNumber *)jitter
{
  NSArray *keys = [NSArray arrayWithObjects:@"host", @"date", @"jitter", nil];
  NSDate * date = [NSDate date];
  NSArray *objects = [NSArray arrayWithObjects:self.hostname, date, jitter, nil];
  NSDictionary *jitterData = [NSDictionary dictionaryWithObjects:objects forKeys:keys];
  return [NSKeyedArchiver archivedDataWithRootObject:jitterData];
}

+ (double) msFromTimestampData:(NSData *)data 
{
  NSDictionary *jitterData = [NSKeyedUnarchiver unarchiveObjectWithData:data];
  NSDate * restoredDate = (NSDate *) [jitterData objectForKey:@"date"];
  return [restoredDate timeIntervalSinceNow] * -1000.0;
}

+ (NSString *) hostFromData:(NSData *)data 
{
  NSDictionary *jitterData = [NSKeyedUnarchiver unarchiveObjectWithData:data];
  NSString *host = (NSString *) [jitterData objectForKey:@"host"];
  return host;
}

+ (NSNumber *) hostJitterFromData:(NSData *)data 
{
  NSDictionary *jitterData = [NSKeyedUnarchiver unarchiveObjectWithData:data];
  NSNumber *jitter = (NSNumber *) [jitterData objectForKey:@"jitter"];
  return jitter;
}



////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Jitter measurements
////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSNumber *)meanOf:(NSArray *)array
{
  double runningTotal = 0.0;
  for(NSNumber *number in array)
  {
    runningTotal += [number doubleValue];
  }
  return [NSNumber numberWithDouble:(runningTotal / [array count])];
}

- (void)addJitterMeasurement:(double)measurement forHost:(NSString*)host
{
  NSMutableArray *measurements = [jitterMeasurements objectForKey:host];
  if (measurements == nil) 
  {
    measurements = [[NSMutableArray alloc] init];
  }
  [measurements addObject:[NSNumber numberWithFloat:measurement]];
  if ([measurements count] > JITTERMESSAGECOUNT)
  {
    [measurements removeLastObject];
  }
  [jitterMeasurements setObject:measurements forKey:host];
  
  // Calculate the jitter
  dispatch_async(jitterCalcQueue, ^{
    double mean = [[self meanOf:measurements] doubleValue];
    double sumOfSquaredDifferences = 0.0;
    for(NSNumber *number in measurements)
    {
      double valueOfNumber = [number doubleValue];
      double difference = valueOfNumber - mean;
      sumOfSquaredDifferences += difference * difference;
    }
    NSNumber *currentJitter = [NSNumber numberWithDouble:(sumOfSquaredDifferences / [measurements count])];
    [jitterCache setValue:currentJitter forKey:host];
  });
}

- (NSNumber *)currentJitterForHost:(NSString *)host
{
  return (NSNumber *) [jitterCache valueForKey:host];
}

- (void)performJitterMeasurements:(NSDictionary*)infoDict {
  @autoreleasepool 
  {
    NSString *host = (NSString *) [infoDict valueForKey:@"host"];
    NSInteger port = [(NSNumber *) [infoDict valueForKey:@"port"] integerValue];
    GCDAsyncSocket *socket = (GCDAsyncSocket *) [infoDict valueForKey:@"receiveSocket"];
    GCDAsyncUdpSocket *jitterSocket = (GCDAsyncUdpSocket *) [infoDict valueForKey:@"sendSocket"];
    
    struct timespec a;
    a.tv_nsec = INTERVAL_BETWEEN_JITTER_MESSAGES;
    a.tv_sec = 0;
    
    NSNumber *currentJitter;
    NSData *payload;
    NSString * jitterHostName = [NSString stringWithFormat:@"%@:%i", host, [socket connectedPort]];
    
    while ([socket isConnected])
    {
      currentJitter = [self currentJitterForHost:jitterHostName];
      if (currentJitter == nil)
        currentJitter = [NSNumber numberWithInt:0];
      payload = [self jitterPayloadContainingJitter:currentJitter];
      nanosleep(&a, NULL);
      @synchronized(jitterSocket)
      {
        [jitterSocket sendData:payload toHost:host port:port withTimeout:-1 tag:JITTERMESSAGE];
      }
    }
  }
}

@end