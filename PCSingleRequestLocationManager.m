//
//  PCWebServiceLocationManager.m
//  Glenigan
//
//  Created by Phillip Caudell on 23/08/2012.
//  Copyright (c) 2012 madebyphill.co.uk. All rights reserved.
//

#import "PCSingleRequestLocationManager.h"
#import <CoreLocation/CoreLocation.h>

#define kPCWebServiceLocationManagerDebug NO
#define kPCWebServiceLocationManagerMaxWaitTime 14.0
#define kPCWebServiceLocationManagerMinWaitTime 2.0

@interface PCSingleRequestLocationManager() <CLLocationManagerDelegate>
{
    BOOL _maxWaitTimeReached;
    BOOL _minWaitTimeReached;
    BOOL _locationSettledUpon;
    NSTimer *_maxWaitTimeTimer;
    NSTimer *_minWaitTimeTimer;
}

@property (nonatomic, retain) CLLocationManager *locationManager;
@property (nonatomic, copy) void (^PCSingleRequestLocationCompletion)(CLLocation *location, NSError *error);

@end;

@implementation PCSingleRequestLocationManager

static PCSingleRequestLocationManager *sharedLocationManager = nil;

- (void)dealloc
{
    self.locationManager.delegate = nil;
    self.locationManager = nil;
}

+ (PCSingleRequestLocationManager *)sharedLocationManager
{
    @synchronized(self) {
        if (sharedLocationManager == nil) {
            sharedLocationManager = [self new];
        }
    }
    
    return sharedLocationManager;
}

- (void)requestCurrentLocationWithCompletion:(PCSingleRequestLocationCompletion)completion
{
    [self requestCurrentLocationWithAuthorizationType:PCAuthorizationTypeWhenInUse completion:completion];
}

- (void)requestCurrentLocationWithAuthorizationType:(PCAuthorizationType)authorization completion:(PCSingleRequestLocationCompletion)completion
{
    self.locationManager = [[CLLocationManager alloc] init];
    self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    self.locationManager.delegate = self;
    
    //Copy completion block for firing later
    self.PCSingleRequestLocationCompletion = completion;
    
    // Start location manager
    if ([self.locationManager respondsToSelector:@selector(requestAlwaysAuthorization)] && [CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorizedAlways && [CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorizedWhenInUse && [CLLocationManager authorizationStatus] != kCLAuthorizationStatusAuthorized) {
        
        if(authorization == PCAuthorizationTypeAlways) {
            
            [self.locationManager requestAlwaysAuthorization];
        } else if(authorization == PCAuthorizationTypeWhenInUse) {
            
            [self.locationManager requestWhenInUseAuthorization];
        }
    } else {
        
        [self.locationManager startUpdatingLocation];
        // Start timers - If user hasn't enabled permissions yet we need to wait until they have allowed/disallowed location updates before starting these timers.
        _maxWaitTimeTimer = [NSTimer scheduledTimerWithTimeInterval:kPCWebServiceLocationManagerMaxWaitTime target:self selector:@selector(maxWaitTimeReached) userInfo:nil repeats:NO];
        _minWaitTimeTimer = [NSTimer scheduledTimerWithTimeInterval:kPCWebServiceLocationManagerMinWaitTime target:self selector:@selector(minWaitTimeReached) userInfo:nil repeats:NO];
    }
}

#pragma mark CLLocationManager delegate

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status
{
    if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
        
        if (self.PCSingleRequestLocationCompletion) { // Only start up if a user has actually requested location by now
            
            [self.locationManager startUpdatingLocation];
            // Start timers
            _maxWaitTimeTimer = [NSTimer scheduledTimerWithTimeInterval:kPCWebServiceLocationManagerMaxWaitTime target:self selector:@selector(maxWaitTimeReached) userInfo:nil repeats:NO];
            _minWaitTimeTimer = [NSTimer scheduledTimerWithTimeInterval:kPCWebServiceLocationManagerMinWaitTime target:self selector:@selector(minWaitTimeReached) userInfo:nil repeats:NO];
        }
    }
    
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        
        NSError *error = [NSError errorWithDomain:@"org.threesidedcube.requestmanager" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"_LOCATIONREQUEST_ALERT_LOCATIONDISABLED_MESSAGE"}];
        self.PCSingleRequestLocationCompletion(nil, error);
        [self cleanUp];
    }
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations
{
    
    if (locations.count > 0) {
        
        CLLocation *newLocation = locations[0];
        
        // Debug the reported location
        if (kPCWebServiceLocationManagerDebug) {
            NSLog(@"PCWebServiceLocationManager: New location: %@", newLocation);
            NSLog(@"PCWebServiceLocationManager: Horizontal accuracy: %f", newLocation.horizontalAccuracy);
            NSLog(@"PCWebServiceLocationManager: Vertical accuracy: %f", newLocation.verticalAccuracy);
        }
        
        // If accuracy greater than 100 meters, it's too inaccurate
        if(newLocation.horizontalAccuracy > 100 && newLocation.verticalAccuracy > 100){
            if (kPCWebServiceLocationManagerDebug) {
                NSLog(@"PCWebServiceLocationManager: Accuracy poor, aborting...");
            }
            return;
        }
        
        // If location is older than 10 seconds, it's probably an old location getting re-reported
        NSInteger locationTimeIntervalSinceNow = abs([newLocation.timestamp timeIntervalSinceNow]);
        if (locationTimeIntervalSinceNow > 10) {
            if (kPCWebServiceLocationManagerDebug) {
                NSLog(@"PCWebServiceLocationManager: Location old, aborting...");
            }
            return;
        }
        
        // If we haven't exceeded our min wait time, it's probably still too inaccurate
        if (!_minWaitTimeReached) {
            if (kPCWebServiceLocationManagerDebug) {
                NSLog(@"PCWebServiceLocationManager: Min wait time not yet reached, aborting...");
            }
            return;
        }
        
        [self settleUponCurrentLocation];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
    if (kPCWebServiceLocationManagerDebug) {
        NSLog(@"PCWebServiceLocationManager: Did fail with error: %@", error);
    }
    
    if(error.code != kCLErrorDenied){
        self.PCSingleRequestLocationCompletion(nil, error);
    }
    
    [self cleanUp];
}

#pragma mark Private helper methods

- (void)maxWaitTimeReached
{
    _maxWaitTimeReached = YES;
    _maxWaitTimeTimer = nil;
    [self settleUponCurrentLocation];
}

- (void)minWaitTimeReached
{
    _minWaitTimeReached = YES;
    _minWaitTimeTimer = nil;
}

/**
 Once all location crtiera has been met
 */
- (void)settleUponCurrentLocation
{
    // If we've already settled upon a location, don't fire again
    if (_locationSettledUpon) {
        return;
    }
    
    if (kPCWebServiceLocationManagerDebug) {
        NSLog(@"PCWebServiceLocationManager: Settling on location: %@", self.locationManager.location);
    }
    
    // Location settled upon!
    _locationSettledUpon = YES;
    
    if (self.PCSingleRequestLocationCompletion) {
        self.PCSingleRequestLocationCompletion(self.locationManager.location, nil);
    }
    
    [self cleanUp];
    
}

- (void)cleanUp
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        
        [self.locationManager stopUpdatingLocation];
        
        self.locationManager.delegate = nil;
        self.locationManager = nil;
        [_maxWaitTimeTimer invalidate];
        _maxWaitTimeTimer = nil;
        [_minWaitTimeTimer invalidate];
        _minWaitTimeTimer = nil;
        _maxWaitTimeReached = NO;
        _minWaitTimeReached = NO;
        _locationSettledUpon = NO;
        self.PCSingleRequestLocationCompletion = nil;
    }];
    
}

@end
