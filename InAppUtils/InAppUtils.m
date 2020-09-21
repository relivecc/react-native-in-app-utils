#import "InAppUtils.h"
#import <StoreKit/StoreKit.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import "SKProduct+StringPrice.h"

@implementation InAppUtils
{
    NSArray *products;
    bool hasListeners;
    bool autoFinishTransactions;
}

- (instancetype)init
{
    if ((self = [super init])) {
        hasListeners = NO;
        autoFinishTransactions = YES;
    }
    return self;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

NSString *const IAPProductsEvent = @"IAP-products";
NSString *const IAPTransactionEvent = @"IAP-transaction";
NSString *const IAPRestoreEvent = @"IAP-restore";

- (NSDictionary *)constantsToExport
{
  return @{ 
      @"IAPProductsEvent": IAPProductsEvent, 
      @"IAPTransactionEvent": IAPTransactionEvent, 
      @"IAPRestoreEvent": IAPRestoreEvent 
  };
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[IAPProductsEvent, IAPTransactionEvent, IAPRestoreEvent];
}

/**
    GUIDE TO LISTENERS:
    source: https://facebook.github.io/react-native/docs/native-modules-ios.html

    import { NativeEventEmitter, NativeModules } from 'react-native';
    const { InAppUtils } = NativeModules;

    const IAPEmitter = new NativeEventEmitter(InAppUtils);

    const subscription = IAPEmitter.addListener(InAppUtils.IAPProductsEvent,
        (response) => console.log(response.state, response) // response can contain error or products dependent on state
    );
    ...
    // Don't forget to unsubscribe, typically in componentWillUnmount
    subscription.remove();
*/

// Will be called when this module's first listener is added.
-(void)startObserving {
    hasListeners = YES;
    [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
}

// Will be called when this module's last listener is removed, or on dealloc.
-(void)stopObserving {
    hasListeners = NO;
    [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
}

RCT_EXPORT_METHOD(setAutoFinishTransactions:(BOOL)autoFinish)
{
    autoFinishTransactions = autoFinish;
}

- (void)paymentQueue:(SKPaymentQueue *)queue
 updatedTransactions:(NSArray *)transactions
{
    if (!hasListeners) { // Only send events if anyone is listening
        RCTLogWarn(@"No listener registered for updated transactions.");
        return;
    }

    NSData *appReceipt = [NSData dataWithContentsOfURL:[[NSBundle mainBundle] appStoreReceiptURL]];
                
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStateFailed: {   
                switch (transaction.error.code)
                {
                    case SKErrorPaymentCancelled:
                        [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"cancelled", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt]}];
                        break;
                    default:
                        [self sendEventWithName:IAPTransactionEvent body:@{@"state": [self RCTJSStringFromTransactionState:transaction.transactionState], @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt], @"error": RCTJSErrorFromNSError(transaction.error)}];
                        break;
                }
                if (autoFinishTransactions) {
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                }
                break;
            }
            case SKPaymentTransactionStatePurchased: 
            case SKPaymentTransactionStateRestored: {
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": [self RCTJSStringFromTransactionState:transaction.transactionState], @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt]}];
                if (autoFinishTransactions) {
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                }
                break;
            }
            case SKPaymentTransactionStatePurchasing:
            case SKPaymentTransactionStateDeferred:
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": [self RCTJSStringFromTransactionState:transaction.transactionState], @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt]}];
                break;
            default:
                break;
        }
    }
}

RCT_EXPORT_METHOD(getTransactionsQueue:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSData *appReceipt = [NSData dataWithContentsOfURL:[[NSBundle mainBundle] appStoreReceiptURL]];
    
    NSMutableArray *productsArrayForJS = [NSMutableArray array];
    for (SKPaymentTransaction *transaction in [[SKPaymentQueue defaultQueue] transactions]) {
        [productsArrayForJS addObject:[self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt]];
    }
    resolve(productsArrayForJS);
}

RCT_EXPORT_METHOD(finishTransaction:(NSString *)transactionIdentifier
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    for (SKPaymentTransaction *transaction in [[SKPaymentQueue defaultQueue] transactions]) {
        if ([transactionIdentifier isEqualToString:transaction.transactionIdentifier]) {
            [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
            resolve(@YES);
            return;
        }
    }
    reject(@"not_found", [NSString stringWithFormat: @"Transaction %@ could not be found", transactionIdentifier], nil);
}

RCT_EXPORT_METHOD(purchaseProductForUser:(NSString *)productIdentifier
                  username:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPurchaseProduct:productIdentifier username:username resolver:resolve rejecter:reject];
}

RCT_EXPORT_METHOD(purchaseProduct:(NSString *)productIdentifier
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPurchaseProduct:productIdentifier username:nil resolver:resolve rejecter:reject];
}

- (void) doPurchaseProduct:(NSString *)productIdentifier
                  username:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject
{
    @try {
        SKProduct *product = [self getProduct:productIdentifier];

        if(product) {
            SKMutablePayment *payment = [SKMutablePayment paymentWithProduct:product];
            if(username) {
                payment.applicationUsername = username;
            }
            [[SKPaymentQueue defaultQueue] addPayment:payment];
            resolve(@YES);
        } else {
            reject(@"invalid_product", nil, nil);
        }
    } @catch (NSException *exception) {
        reject(@"purchase_product_exception", exception.reason, nil);
    }
}

- (void)paymentQueue:(SKPaymentQueue *)queue
restoreCompletedTransactionsFailedWithError:(NSError *)error
{
    if (hasListeners) { // Only send events if anyone is listening
        switch (error.code)
        {
            case SKErrorPaymentCancelled:
                [self sendEventWithName:IAPRestoreEvent body:@{@"state": @"cancelled", @"error": RCTJSErrorFromNSError(error)}];
                break;
            default:
                [self sendEventWithName:IAPRestoreEvent body:@{@"state": @"error", @"error": RCTJSErrorFromNSError(error)}];
                break;
        }
    } else {
        RCTLogWarn(@"No listener registered for restore product request.");
    }
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
    if (hasListeners) { // Only send events if anyone is listening
        NSData *appReceipt = [NSData dataWithContentsOfURL:[[NSBundle mainBundle] appStoreReceiptURL]];
                
        NSMutableArray *productsArrayForJS = [NSMutableArray array];
        for(SKPaymentTransaction *transaction in queue.transactions){
            if(transaction.transactionState == SKPaymentTransactionStateRestored) {
                [productsArrayForJS addObject:[self RCTJSTransactionFromSKPaymentTransaction:transaction withAppReceipt:appReceipt]];
                if (autoFinishTransactions) {
                    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                }
            }
        }
        [self sendEventWithName:IAPRestoreEvent body:@{@"state": @"success", @"products": productsArrayForJS}];
    } else {
        RCTLogWarn(@"No listener registered for restore product request.");
    }
}

RCT_EXPORT_METHOD(restorePurchases:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    if (!hasListeners) { // Only initiate restore if anyone is listening
        RCTLogWarn(@"No listener registered for restore purchases request.");
        reject(@"no_listener", @"No listener registered for restore purchases request.", nil);
        return;
    }

    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
    resolve(@YES);
}

RCT_EXPORT_METHOD(restorePurchasesForUser:(NSString *)username
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    if (!hasListeners) { // Only initiate restore if anyone is listening
        RCTLogWarn(@"No listener registered for restore purchases request.");
        reject(@"no_listener", @"No listener registered for restore purchases request.", nil);
        return;
    }

    if(!username) {
        reject(@"username_required", nil, nil);
        return;
    }
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactionsWithApplicationUsername:username];
    resolve(@YES);
}

RCT_EXPORT_METHOD(loadProducts:(NSArray *)productIdentifiers
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    if (!hasListeners) { // Only load products if anyone is listening
        RCTLogWarn(@"No listener registered for load product request.");
        reject(@"no_listener", @"No listener registered for load products request.", nil);
        return;
    }

    SKProductsRequest *productsRequest = [[SKProductsRequest alloc]
                                        initWithProductIdentifiers:[NSSet setWithArray:productIdentifiers]];
    productsRequest.delegate = self;
    [productsRequest start];
    resolve(@YES);
}

RCT_EXPORT_METHOD(canMakePayments:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    BOOL canMakePayments = [SKPaymentQueue canMakePayments];
    resolve(@(canMakePayments));
}

RCT_EXPORT_METHOD(receiptData:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    NSURL *receiptUrl = [[NSBundle mainBundle] appStoreReceiptURL];
    NSData *receiptData = [NSData dataWithContentsOfURL:receiptUrl];
    if (!receiptData) {
      reject(@"not_available", nil, nil);
    } else {
      resolve([receiptData base64EncodedStringWithOptions:0]);
    }
}

// SKProductsRequestDelegate protocol method
- (void)productsRequest:(SKProductsRequest *)request
     didReceiveResponse:(SKProductsResponse *)response
{
    if (hasListeners) { // Only send events if anyone is listening
        products = [NSMutableArray arrayWithArray:response.products];
        NSMutableArray *productsArrayForJS = [NSMutableArray array];
        for(SKProduct *item in response.products) {
            [productsArrayForJS addObject:[self RCTJSProductFromSKProduct:item]];
        }
        [self sendEventWithName:IAPProductsEvent body:@{@"state": @"success", @"products": productsArrayForJS}];
    } else {
        RCTLogWarn(@"No listener registered for load product request.");
    }
}

// SKProductsRequestDelegate network error
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error{
    [self sendEventWithName:IAPProductsEvent body:@{@"state": @"error", @"error": RCTJSErrorFromNSError(error)}];
}

#pragma mark Private

- (NSString *)RCTJSStringFromTransactionState:(SKPaymentTransactionState)state {
    switch (state) {
        case SKPaymentTransactionStateFailed:
            return @"error";
        case SKPaymentTransactionStatePurchased:
            return @"success";
        case SKPaymentTransactionStateRestored:
            return @"restored";
        case SKPaymentTransactionStatePurchasing:
            return @"purchasing";
        case SKPaymentTransactionStateDeferred:
            return @"deferred";
        default:
            break;
    }
}

- (NSDictionary *)RCTJSTransactionFromSKPaymentTransaction:(SKPaymentTransaction *)transaction withAppReceipt:(NSData *)appReceipt {
    NSMutableDictionary *purchase = [NSMutableDictionary dictionaryWithDictionary: @{
        @"transactionState": [self RCTJSStringFromTransactionState:transaction.transactionState],
        @"transactionDate": transaction.transactionDate ? @(transaction.transactionDate.timeIntervalSince1970 * 1000) : [NSNumber numberWithInt:0],
        @"transactionIdentifier": transaction.transactionIdentifier ? transaction.transactionIdentifier : @"",
        @"productIdentifier": transaction.payment.productIdentifier,
    }];

    if ([transaction transactionReceipt]) {
        purchase[@"transactionReceipt"] = [[transaction transactionReceipt] base64EncodedStringWithOptions:0];
    }

    // transactionReceipt is deprecated since iOS 7
    if (appReceipt) {
        purchase[@"appReceipt"] = [appReceipt base64EncodedStringWithOptions:0];
    }

    if (transaction.payment) {
        NSDictionary *payment = @{
            @"applicationUsername": transaction.payment.applicationUsername ? transaction.payment.applicationUsername : @"",
            @"productIdentifier": transaction.payment.productIdentifier,
            @"quantity": [NSNumber numberWithInt:transaction.payment.quantity],
            @"requestData": transaction.payment.requestData ? transaction.payment.requestData : @""
        };
        purchase[@"payment"] = payment;
    }

    SKProduct *product = [self getProduct:transaction.payment.productIdentifier];
    if (product) {
        purchase[@"product"] = [self RCTJSProductFromSKProduct:product];
    }

    SKPaymentTransaction *originalTransaction = transaction.originalTransaction;
    if (originalTransaction) {
        purchase[@"originalTransactionDate"] = @(originalTransaction.transactionDate.timeIntervalSince1970 * 1000);
        purchase[@"originalTransactionIdentifier"] = originalTransaction.transactionIdentifier;
    }

    return purchase;
}

- (NSDictionary *)RCTJSProductFromSKProduct:(SKProduct *)item {
    NSMutableDictionary *product = [NSMutableDictionary dictionaryWithDictionary: @{
        @"identifier": item.productIdentifier,
        @"price": item.price,
        @"currencySymbol": [item.priceLocale objectForKey:NSLocaleCurrencySymbol],
        @"currencyCode": [item.priceLocale objectForKey:NSLocaleCurrencyCode],
        @"priceString": item.priceString,
        @"countryCode": [item.priceLocale objectForKey: NSLocaleCountryCode],
        @"downloadable": item.isDownloadable ? @"true" : @"false",
        @"description": item.localizedDescription ? item.localizedDescription : @"",
        @"title": item.localizedTitle ? item.localizedTitle : @"",
    }];
    
    if (@available(iOS 11.2, *)) {
        if (item.introductoryPrice) {
            product[@"introductoryPrice"] = @"available"; // TODO serialize introductoryPrice object
        }
    }
    
    return product;
}

- (SKProduct *)getProduct:(NSString *)productIdentifier {
    for(SKProduct *p in products) {
        if([productIdentifier isEqualToString:p.productIdentifier]) {
            return p;
        }
    }
    return nil;
}

@end
