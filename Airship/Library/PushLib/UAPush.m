/*
 Copyright 2009-2012 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <UIKit/UIKit.h>

#import "UAPush.h"
#import "UA_ASIHTTPRequest.h"
#import "UAirship.h"
#import "UAViewUtils.h"
#import "UAUtils.h"
#import "UAAnalytics.h"
#import "UAPush+Internal.h"
#import "UA_SBJsonWriter.h"
#import "UAEvent.h"


UA_VERSION_IMPLEMENTATION(UAPushVersion, UA_VERSION)

UAPushSettingsKey *const UAPushEnabledSettingsKey = @"UAPushEnabled";
UAPushSettingsKey *const UAPushAliasSettingsKey = @"UAPushAlias";
UAPushSettingsKey *const UAPushTagsSettingsKey = @"UAPushTags";
UAPushSettingsKey *const UAPushBadgeSettingsKey = @"UAPushBadge";
UAPushSettingsKey *const UAPushQuietTimeSettingsKey = @"UAPushQuietTime";
UAPushSettingsKey *const UAPushTimeZoneSettingsKey = @"UAPushTimeZone";
UAPushSettingsKey *const UAPushDeviceTokenSettingsKey = @"UAPushDeviceToken";

UAPushJSONKey *const UAPushMultipleTagsJSONKey = @"tags";
UAPushJSONKey *const UAPushSingleTagJSONKey = @"tag";
UAPushJSONKey *const UAPushAliasJSONKey = @"alias";
UAPushJSONKey *const UAPushQuietTimeJSONKey = @"quiettime";
UAPushJSONKey *const UAPushTimeZoneJSONKey = @"tz";
UAPushJSONKey *const UAPushBadgeJSONKey = @"badge";

UAPushStorageKey *const UAPushTimezoneNameKey = @"UAPushTimezoneName";
UAPushStorageKey *const UAPushTimezoneOffesetKey = @"UAPushTimezoneOffset";
UAPushStorageKey *const UAPushTimezoneIsDaylightSavingsKey = @"UAPushTimezoneIsDaylightSavings";


@implementation UAPush

@synthesize delegate;
@synthesize autobadgeEnabled = autobadgeEnabled_;
@synthesize notificationTypes;
@synthesize standardUserDefaults = standardUserDefaults_;

SINGLETON_IMPLEMENTATION(UAPush)

static Class _uiClass;

-(void)dealloc {
    [[UAirship shared] removeObserver:self];
    RELEASE_SAFELY(defaultPushHandler);
    RELEASE_SAFELY(deviceToken_);
    [super dealloc];
}

- (id)init {
    self = [super init];
    if (self) {
        //init with default delegate implementation
        // TODO: This leaks, change so that it is lazy loaded when needed and 
        // released when replaced
        defaultPushHandler = [[NSClassFromString(PUSH_DELEGATE_CLASS) alloc] init];
        self.delegate = defaultPushHandler;
        standardUserDefaults_ = [NSUserDefaults standardUserDefaults];
        // Push enabled defaults to on
        if (![self pushEnabled]) {
            [self setPushEnabled:YES];
        }
        [[UAirship shared] addObserver:self];
    }
    return self;
}

#pragma mark -
#pragma mark Device Token Get/Set Methods

- (NSString *)deviceToken {
    return deviceToken_;
}

- (void)setDeviceToken:(NSData *)deviceToken {
    NSString* token = [self parseDeviceToken:[deviceToken description]];
    if (!token) {
        UALOG(@"Problem with parsing the device token");
    }
    else {
        [deviceToken_ release];
        deviceToken_ = [token copy];
        UALOG(@"Device token: %@", deviceToken_);    
        NSString* oldValue = [[NSUserDefaults standardUserDefaults] stringForKey:UAPushDeviceTokenSettingsKey];
        if(![oldValue isEqualToString: deviceToken_]) {
            deviceTokenHasChanged_ = YES;
            [[NSUserDefaults standardUserDefaults] setObject:deviceToken_ forKey:UAPushDeviceTokenSettingsKey];
        }
    }
    return;
}

- (NSString*)parseDeviceToken:(NSString*)tokenStr {
    return [[[tokenStr stringByReplacingOccurrencesOfString:@"<" withString:@""]
             stringByReplacingOccurrencesOfString:@">" withString:@""]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
}

#pragma mark -
#pragma mark Get/Set Methods

- (BOOL)deviceTokenHasChanged {
    return deviceTokenHasChanged_;
}

- (NSString *)alias {
    return [standardUserDefaults_ stringForKey:UAPushAliasJSONKey];
}

- (void)setAlias:(NSString *)alias {
    [standardUserDefaults_ setObject:alias forKey:UAPushAliasJSONKey];
}

- (NSMutableArray *)tags {
    NSArray *array = [standardUserDefaults_ objectForKey:UAPushTagsSettingsKey];
    return [NSMutableArray arrayWithArray:array];
}

- (void)setTags:(NSMutableArray *)tags {
    // TODO: Setup block to search for duplicates and get rid of them
    [standardUserDefaults_ setObject:tags forKey:UAPushTagsSettingsKey];
}

- (BOOL)pushEnabled {
    return [standardUserDefaults_ boolForKey:UAPushEnabledSettingsKey];
}

- (void)setPushEnabled:(BOOL)pushEnabled {
    [standardUserDefaults_ setBool:pushEnabled forKey:UAPushEnabledSettingsKey];
}

- (NSMutableDictionary *)quietTime {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:[standardUserDefaults_ dictionaryForKey:UAPushQuietTimeSettingsKey]];
    return dictionary;
}

- (void)setQuietTime:(NSMutableDictionary *)quietTime {
    [standardUserDefaults_ setObject:quietTime forKey:UAPushQuietTimeSettingsKey];
}

- (NSString *)tz {
    return self.timeZone.name;
}

- (void)setTz:(NSString *)tz {
    NSTimeZone* timeZone = [NSTimeZone timeZoneWithName:tz];
    self.timeZone = timeZone;
}

- (NSTimeZone *)timeZone {
    NSDictionary* timeZoneStorage = [standardUserDefaults_ dictionaryForKey:UAPushTimeZoneSettingsKey];
    if (!timeZoneStorage) {
        self.timeZone = nil; // write out the default time zone to user defaults
        return self.defaultTimeZoneForPush;
    }
    NSTimeZone *storedTimeZone = [NSTimeZone timeZoneWithName:[timeZoneStorage valueForKey:UAPushTimezoneNameKey]]; 
    // If that came back nil, create a time zone based on offset
    if(!storedTimeZone){
        storedTimeZone = [NSTimeZone timeZoneForSecondsFromGMT:[[timeZoneStorage valueForKey:UAPushTimezoneOffesetKey] intValue]];
    }
    return storedTimeZone;
}

- (void)setTimeZone:(NSTimeZone *)timeZone {
    NSMutableDictionary* timeZoneStorage = [NSMutableDictionary dictionaryWithCapacity:3];
    if (!timeZone) {
        timeZone = [self defaultTimeZoneForPush];
    }
    [timeZoneStorage setValue:timeZone.name forKey:UAPushTimezoneNameKey];
    [timeZoneStorage setValue:[NSNumber numberWithBool:timeZone.isDaylightSavingTime] forKey:UAPushTimezoneIsDaylightSavingsKey];
    [timeZoneStorage setValue:[NSNumber numberWithInt:timeZone.secondsFromGMT] forKey:UAPushTimezoneOffesetKey];
    [standardUserDefaults_ setObject:timeZoneStorage forKey:UAPushTimeZoneSettingsKey];
}

- (NSTimeZone *)defaultTimeZoneForPush {
    return [NSTimeZone localTimeZone];
}


#pragma mark -
#pragma mark Private methods

- (Class)uiClass {
    if (!_uiClass) {
        _uiClass = NSClassFromString(PUSH_UI_CLASS);
    }
    
    if (_uiClass == nil) {
        UALOG(@"Push UI class not found.");
    }
    
    return _uiClass;
}

- (NSString *)getTagFromUrl:(NSURL *)url {
    return [[url.relativePath componentsSeparatedByString:@"/"] lastObject];
}

- (void)updateRegistration {
    [standardUserDefaults_ synchronize];
    //if on, but not yet registered, re-register -- was likely just enabled
    BOOL pushEnabled = self.pushEnabled;
    if (pushEnabled && deviceToken_) {
        [self registerForRemoteNotificationTypes:notificationTypes];
        
    //if enabled, simply update existing device token
    } else if (pushEnabled) {
        [self registerDeviceToken:nil];
        
    // unregister token w/ UA
    } else {
        [self unRegisterDeviceToken];
    }
}

#pragma mark -
#pragma mark APNS wrapper
- (void)registerForRemoteNotificationTypes:(UIRemoteNotificationType)types {
    notificationTypes = types;
    
    if (self.pushEnabled) {
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes:notificationTypes];
    }
}

//The new token to register, or nil if updating the existing token
- (void)registerDeviceToken:(NSData *)token {
    NSMutableDictionary *body = [self registrationPayload];
    if (token != nil) {
		UALOG("Updating device token (%@) with: %@", token, body);
        [self registerDeviceToken:token withExtraInfo:body];
    } else {
		UALOG("Updating device existing token with: %@", body);
        [self registerDeviceTokenWithExtraInfo:body];
    }

}

- (NSMutableDictionary *)registrationPayload {
    
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    NSString* alias =  self.alias;
    if (alias != nil) {
        [body setObject:alias forKey:UAPushAliasJSONKey];
    }
    NSMutableArray *tags = self.tags;
    if (tags != nil && tags.count != 0) {
        [body setObject:tags forKey:UAPushMultipleTagsJSONKey];
    }
    
    NSString* tz = self.timeZone.name;
    NSMutableDictionary *quietTime = self.quietTime;
    if (tz != nil && quietTime != nil && [quietTime count] > 0) {
        [body setObject:tz forKey:UAPushTimeZoneJSONKey];
        [body setObject:quietTime forKey:UAPushQuietTimeJSONKey];
    }
    if (autobadgeEnabled_) {
        [body setObject:[NSNumber numberWithInteger:[[UIApplication sharedApplication] applicationIconBadgeNumber]] forKey:UAPushBadgeJSONKey];
    }
    return body;
}
#pragma mark -
#pragma mark UA Registration callbacks

- (void)addTagToDeviceFailed:(UA_ASIHTTPRequest *)request {
    UALOG(@"Using U/P: %@ / %@", request.username, request.password);
    [UAUtils requestWentWrong:request keyword:@"add tag to current device"];
    [self notifyObservers:@selector(addTagToDeviceFailed:) withObject:[request error]];
}

- (void)addTagToDeviceSucceed:(UA_ASIHTTPRequest *)request {
    if (request.responseStatusCode != 200 && request.responseStatusCode != 201){
        [self addTagToDeviceFailed:request];
    } else {
        UALOG(@"Tag added successfully: %d - %@", request.responseStatusCode, request.url);
        [self notifyObservers:@selector(addTagToDeviceSucceeded)];
    }
}

- (void)removeTagFromDeviceFailed:(UA_ASIHTTPRequest *)request {
    UALOG(@"Using U/P: %@ / %@", request.username, request.password);
    [UAUtils requestWentWrong:request keyword:@"remove tag from current device"];
    [self notifyObservers:@selector(removeTagFromDeviceFailed:) withObject:[request error]];
}

- (void)removeTagFromDeviceSucceed:(UA_ASIHTTPRequest *)request {

    switch (request.responseStatusCode) {
        case 204://just removed
        case 404://already removed
            UALOG(@"Tag removed from server successfully: %d - %@", request.responseStatusCode, request.url);
            [self notifyObservers:@selector(removeTagFromDeviceSucceeded)];
            break;
        default:
            [self removeTagFromDeviceFailed:request];
            break;
    }
}

#pragma mark -
#pragma mark Open APIs - Property Setters

- (void)updateAlias:(NSString *)value {
    self.alias = value;
    [self updateRegistration];
}

- (void)updateTags:(NSMutableArray *)value {
    self.tags = value;
    [self updateRegistration];
}

- (void)setQuietTimeFrom:(NSDate *)from to:(NSDate *)to withTimeZone:(NSTimeZone *)timezone {
    if (!from || !to) {
        UALOG(@"Set Quiet Time - parameter is nil. from: %@ to: %@", from, to);
        return;
    }
    if(!timezone){
        timezone = [self defaultTimeZoneForPush];
    }
    NSCalendar *cal = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
    NSString *fromStr = [NSString stringWithFormat:@"%d:%02d",
                         [cal components:NSHourCalendarUnit fromDate:from].hour,
                         [cal components:NSMinuteCalendarUnit fromDate:from].minute];
    
    NSString *toStr = [NSString stringWithFormat:@"%d:%02d",
                       [cal components:NSHourCalendarUnit fromDate:to].hour,
                       [cal components:NSMinuteCalendarUnit fromDate:to].minute];
    
    self.quietTime = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                      fromStr, @"start",
                      toStr, @"end", nil];
    
    self.timeZone = timezone;
    [self updateRegistration];
}

- (void)disableQuietTime {
    [self.quietTime removeAllObjects];
    [self updateRegistration];
}

#pragma mark -
#pragma mark Open APIs

+ (void)land {
    
    // not much teardown to do here, but implement anyway for the future
    if (g_sharedUAPush) {
        RELEASE_SAFELY(g_sharedUAPush);
    }
}

#pragma mark -
#pragma mark Open APIs - Custom UI

+ (void)useCustomUI:(Class)customUIClass {
    _uiClass = customUIClass;
}

#pragma mark -
#pragma mark Open APIs - UI Display

+ (void)openApnsSettings:(UIViewController *)viewController
                animated:(BOOL)animated {
    [[[UAPush shared] uiClass] openApnsSettings:viewController animated:animated];
}

+ (void)openTokenSettings:(UIViewController *)viewController
                 animated:(BOOL)animated {
    [[[UAPush shared] uiClass] openTokenSettings:viewController animated:animated];
}

+ (void)closeApnsSettingsAnimated:(BOOL)animated {
    [[[UAPush shared] uiClass] closeApnsSettingsAnimated:animated];
}

+ (void)closeTokenSettingsAnimated:(BOOL)animated {
    [[[UAPush shared] uiClass] closeTokenSettingsAnimated:animated];
}

#pragma mark -
#pragma mark Open APIs - UA Registration Tags APIs

- (void)addTagToCurrentDevice:(NSString *)tag {
    NSString *encodedTag = [UAUtils urlEncodedStringWithString:tag encoding:NSUTF8StringEncoding];
    NSString *urlString = [NSString stringWithFormat:@"%@/api/device_tokens/%@/tags/%@",
                           [[UAirship shared] server],
                           [[UAirship shared] deviceToken],
                           encodedTag];
    
    NSURL *url = [NSURL URLWithString:urlString];
    UA_ASIHTTPRequest *request = [UAUtils requestWithURL:url
                                       method:@"PUT"
                                     delegate:self
                                       finish:@selector(addTagToDeviceSucceed:)
                                         fail:@selector(addTagToDeviceFailed:)];
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setValue:tag forKey:UAPushSingleTagJSONKey];
    request.userInfo = userInfo;
    
    [request startAsynchronous];
}

- (void)removeTagFromCurrentDevice:(NSString *)tag {
    NSString *encodedTag = [UAUtils urlEncodedStringWithString:tag encoding:NSUTF8StringEncoding];
    NSString *urlString = [NSString stringWithFormat:@"%@/api/device_tokens/%@/tags/%@",
                           [[UAirship shared] server],
                           [[UAirship shared] deviceToken],
                           encodedTag];
    
    NSURL *url = [NSURL URLWithString:urlString];
    UA_ASIHTTPRequest *request = [UAUtils requestWithURL:url
                                       method:@"DELETE"
                                     delegate:self
                                       finish:@selector(removeTagFromDeviceSucceed:)
                                         fail:@selector(removeTagFromDeviceFailed:)];
    
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setValue:tag forKey:UAPushSingleTagJSONKey];
    request.userInfo = userInfo;

    [request startAsynchronous];
}

- (void)enableAutobadge:(BOOL)autobadge {
    autobadgeEnabled_ = autobadge;
}

- (void)setBadgeNumber:(NSInteger)badgeNumber {

    if ([[UIApplication sharedApplication] applicationIconBadgeNumber] == badgeNumber) {
        return;
    }
    
    UALOG(@"Change Badge from %d to %d", [[UIApplication sharedApplication] applicationIconBadgeNumber], badgeNumber);
    
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badgeNumber];
    
    // if the device token has already been set then
    // we are post-registration and will need to make
    // and update call
    if (autobadgeEnabled_ && [UAirship shared].deviceToken) {
        UALOG(@"Sending autobadge update to UA server");
        [self updateRegistration];
    }
}

- (void)resetBadge {
    [self setBadgeNumber:0];
}

- (void)handleNotification:(NSDictionary *)notification applicationState:(UIApplicationState)state {
    
    [[UAirship shared].analytics handleNotification:notification];
        
    if (state != UIApplicationStateActive) {
        UALOG(@"Received a notification for an inactive application state.");
        
        if ([delegate respondsToSelector:@selector(handleBackgroundNotification:)])
            [delegate handleBackgroundNotification:notification];
        return;
    }
    
    // Please refer to the following Apple documentation for full details on handling the userInfo payloads
	// http://developer.apple.com/library/ios/#documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/ApplePushService/ApplePushService.html#//apple_ref/doc/uid/TP40008194-CH100-SW1
	
	if ([[notification allKeys] containsObject:@"aps"]) { 
		
        NSDictionary *apsDict = [notification objectForKey:@"aps"];
        
		if ([[apsDict allKeys] containsObject:@"alert"]) {

			if ([[apsDict objectForKey:@"alert"] isKindOfClass:[NSString class]] &&
                [delegate respondsToSelector:@selector(displayNotificationAlert:)]) {
                
				// The alert is a single string message so we can display it
                [delegate displayNotificationAlert:[apsDict valueForKey:@"alert"]];

			} else if ([delegate respondsToSelector:@selector(displayLocalizedNotificationAlert:)]) {
				// The alert is a a dictionary with more localization details
				// This should be customized to fit your message details or usage scenario
                [delegate displayLocalizedNotificationAlert:[apsDict valueForKey:@"alert"]];
			}
			
		}
        
        //badge
        NSString *badgeNumber = [apsDict valueForKey:@"badge"];
        if (badgeNumber) {
			
			if(autobadgeEnabled_) {
				[[UIApplication sharedApplication] setApplicationIconBadgeNumber:[badgeNumber intValue]];
			} else if ([delegate respondsToSelector:@selector(handleBadgeUpdate:)]) {
				[delegate handleBadgeUpdate:[badgeNumber intValue]];
			}
        }
		
        //sound
		NSString *soundName = [apsDict valueForKey:@"sound"];
		if (soundName && [delegate respondsToSelector:@selector(playNotificationSound:)]) {
			[delegate playNotificationSound:[apsDict objectForKey:@"sound"]];
		}
        
	}//aps
    
	// Now remove all the UA and Apple payload items
	NSMutableDictionary *customPayload = [[notification mutableCopy] autorelease];
	
	if([[customPayload allKeys] containsObject:@"aps"]) {
		[customPayload removeObjectForKey:@"aps"];
	}
	if([[customPayload allKeys] containsObject:@"_uamid"]) {
		[customPayload removeObjectForKey:@"_uamid"];
	}
	if([[customPayload allKeys] containsObject:@"_"]) {
		[customPayload removeObjectForKey:@"_"];
	}
	
	// If any top level items remain, those are custom payload, pass it to the handler
	// Note: There is some convenience built into this check, if for some reason there's a key collision
	//	and we're stripping yours above, it's safe to remove this conditional
	if([[customPayload allKeys] count] > 0 && [delegate respondsToSelector:@selector(handleNotification:withCustomPayload:)]) {
		[delegate handleNotification:notification withCustomPayload:customPayload];
    }
}

+ (NSString *)pushTypeString:(UIRemoteNotificationType)types {
    
    //TODO: Localize
    
    //UIRemoteNotificationType types = [[UIApplication sharedApplication] enabledRemoteNotificationTypes];
    
    NSMutableArray *typeArray = [NSMutableArray arrayWithCapacity:3];

    //Use the same order as the Settings->Notifications panel
    if (types & UIRemoteNotificationTypeBadge) {
        [typeArray addObject:@"Badges"];
    }
    
    if (types & UIRemoteNotificationTypeAlert) {
        [typeArray addObject:@"Alerts"];
    }
    
    if (types & UIRemoteNotificationTypeSound) {
        [typeArray addObject:@"Sounds"];
    }
    
    if ([typeArray count] > 0) {
        return [typeArray componentsJoinedByString:@", "];
    }
    
    return @"None";
}


- (void)registerDeviceTokenWithExtraInfo:(NSDictionary *)info {
    
    // if the application is backgrounded, do not send a registration
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        UALOG(@"Skipping DT registration. The app is currently backgrounded.");
        return;
    }
    
    
    NSString *urlString = [NSString stringWithFormat:@"%@%@%@/",
                           [UAirship shared].server, @"/api/device_tokens/",
                           deviceToken_];
    NSURL *url = [NSURL URLWithString:urlString];
    UA_ASIHTTPRequest *request = [UAUtils requestWithURL:url
                                                  method:@"PUT"
                                                delegate:self
                                                  finish:@selector(registerDeviceTokenSucceeded:)
                                                    fail:@selector(registerDeviceTokenFailed:)];
    if (info != nil) {
        [request addRequestHeader: @"Content-Type" value: @"application/json"];
        UA_SBJsonWriter *writer = [UA_SBJsonWriter new];
        [request appendPostData:[[writer stringWithObject:info] dataUsingEncoding:NSUTF8StringEncoding]];
        [writer release];
    }
    
    [request startAsynchronous];
    
}

- (void)registerDeviceToken:(NSData *)token withExtraInfo:(NSDictionary *)info {
    
    self.deviceToken = [self parseDeviceToken:[token description]];
    [self registerDeviceTokenWithExtraInfo:info];
    
    // add device_registration event
    [[UAirship shared].analytics addEvent:[UAEventDeviceRegistration eventWithContext:nil]];
}

- (void)registerDeviceToken:(NSData *)token withAlias:(NSString *)alias {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    if (alias != nil) {
        [body setObject:alias forKey:@"alias"];
    }
    [self registerDeviceToken:token withExtraInfo:body];
}

- (void)unRegisterDeviceToken {
    
    if (deviceToken_ == nil) {
        UALOG(@"Skipping unRegisterDeviceToken: no device token found.");
        return;
    }
    
    NSString *urlString = [NSString stringWithFormat:@"%@/api/device_tokens/%@/",
                           [UAirship shared].server,
                           deviceToken_];
    NSURL *url = [NSURL URLWithString:urlString];
    UALOG(@"Request to unregister device token.");
    UA_ASIHTTPRequest *request = [UAUtils requestWithURL:url
                                                  method:@"DELETE"
                                                delegate:self
                                                  finish:@selector(unRegisterDeviceTokenSucceeded:)
                                                    fail:@selector(unRegisterDeviceTokenFailed:)];
    [request startAsynchronous];
}

#pragma mark -
#pragma mark UA Registration callbacks

- (void)registerDeviceTokenFailed:(UA_ASIHTTPRequest *)request {
    [UAUtils requestWentWrong:request keyword:@"registering device token"];
    [self notifyObservers:@selector(registerDeviceTokenFailed:)
               withObject:request];
}

- (void)registerDeviceTokenSucceeded:(UA_ASIHTTPRequest *)request {
    if(request.responseStatusCode != 200 && request.responseStatusCode != 201) {
        [self registerDeviceTokenFailed:request];
    } else {
        UALOG(@"Device token registered on Urban Airship successfully.");
        [self notifyObservers:@selector(registerDeviceTokenSucceeded)];
    }
}

- (void)unRegisterDeviceTokenFailed:(UA_ASIHTTPRequest *)request {
    [UAUtils requestWentWrong:request keyword:@"unRegistering device token"];
    [self notifyObservers:@selector(unRegisterDeviceTokenFailed:)
               withObject:request];
}

- (void)unRegisterDeviceTokenSucceeded:(UA_ASIHTTPRequest *)request {
    if (request.responseStatusCode != 204){
        [self unRegisterDeviceTokenFailed:request];
    } else {
        UALOG(@"Device token unregistered on Urban Airship successfully.");
        self.deviceToken = nil;
        [self notifyObservers:@selector(unRegisterDeviceTokenSucceeded)];
    }
}

@end
