#import "InAppUtils.h"
#import <StoreKit/StoreKit.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import "SKProduct+StringPrice.h"

@implementation InAppUtils
{
    NSArray *products;
    bool hasListeners;
}

- (instancetype)init
{
    if ((self = [super init])) {
        hasListeners = NO;
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

- (void)paymentQueue:(SKPaymentQueue *)queue
 updatedTransactions:(NSArray *)transactions
{
    if (!hasListeners) { // Only send events if anyone is listening
        RCTLogWarn(@"No listener registered for updated transactions.");
        return;
    }
                
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStateFailed: {   
                switch (transaction.error.code)
                {
                    case SKErrorPaymentCancelled:
                        [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"cancelled", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction]}];
                        break;
                    default:
                        [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"error", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction], @"error": RCTJSErrorFromNSError(transaction.error)}];
                        break;
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStatePurchased: {
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"success", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction]}];
                // TODO remove finishTransaction here, and create separate method
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStateRestored:
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"restored", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction]}];
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStatePurchasing:
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"purchasing", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction]}];
                break;
            case SKPaymentTransactionStateDeferred:
                [self sendEventWithName:IAPTransactionEvent body:@{@"state": @"deferred", @"transaction": [self RCTJSTransactionFromSKPaymentTransaction:transaction]}];
                break;
            default:
                break;
        }
    }
}

RCT_EXPORT_METHOD(finishTransaction:(NSString *)transactionIdentifier)
{
    // TODO fetch transaction from an array (is this waterproof?) to be finished here
    // [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
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
        reject(@"purchase_product_exception", exception.reason, exception);
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
        NSMutableArray *productsArrayForJS = [NSMutableArray array];
        for(SKPaymentTransaction *transaction in queue.transactions){
            if(transaction.transactionState == SKPaymentTransactionStateRestored) {
                [productsArrayForJS addObject:[self RCTJSTransactionFromSKPaymentTransaction:transaction]];
                // TODO remove finishTransaction here, and create separate method
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
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

- (NSDictionary *)RCTJSTransactionFromSKPaymentTransaction:(SKPaymentTransaction *)transaction{
    NSDictionary *payment = @{
        @"applicationUsername": transaction.payment.applicationUsername ? transaction.payment.applicationUsername : @"",
        @"productIdentifier": transaction.payment.productIdentifier,
        @"quantity": [NSNumber numberWithInt:transaction.payment.quantity],
        @"requestData": transaction.payment.requestData ? transaction.payment.requestData : @""
    };

    NSMutableDictionary *purchase = [NSMutableDictionary dictionaryWithDictionary: @{
        @"transactionDate": @(transaction.transactionDate.timeIntervalSince1970 * 1000),
        @"transactionIdentifier": transaction.transactionIdentifier,
        @"productIdentifier": transaction.payment.productIdentifier,
        @"transactionReceipt": [[transaction transactionReceipt] base64EncodedStringWithOptions:0],
        @"payment": payment,
    }];

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
    NSDictionary *product = @{
        @"identifier": item.productIdentifier,
        @"price": item.price,
        @"currencySymbol": [item.priceLocale objectForKey:NSLocaleCurrencySymbol],
        @"currencyCode": [item.priceLocale objectForKey:NSLocaleCurrencyCode],
        @"priceString": item.priceString,
        @"countryCode": [item.priceLocale objectForKey: NSLocaleCountryCode],
        @"downloadable": item.downloadable ? @"true" : @"false" ,
        @"description": item.localizedDescription ? item.localizedDescription : @"",
        @"title": item.localizedTitle ? item.localizedTitle : @"",
    };
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
