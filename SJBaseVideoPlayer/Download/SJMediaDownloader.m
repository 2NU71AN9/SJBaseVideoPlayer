//
//  SJMediaDownloader.m
//  SJMediaDownloader
//
//  Created by BlueDancer on 2018/3/13.
//  Copyright © 2018年 SanJiang. All rights reserved.
//

#import "SJMediaDownloader.h"
#import <sqlite3.h>
#import <objc/message.h>
#import <sys/xattr.h>

NS_ASSUME_NONNULL_BEGIN

#define DEBUG_CONDITION 0

inline static bool sql_exe(sqlite3 *database, const char *sql);
inline static NSArray<id> *sql_query(sqlite3 *database, const char *sql, Class cls);

typedef NS_ENUM(NSInteger, SJMediaDownloadErrorCode) {
    SJMediaDownloadErrorCode_Unknown = NSURLErrorUnknown,
    SJMediaDownloadErrorCode_Cancelled = NSURLErrorCancelled,
    SJMediaDownloadErrorCode_BadURL = NSURLErrorBadURL,
    SJMediaDownloadErrorCode_TimeOut = NSURLErrorTimedOut,
    SJMediaDownloadErrorCode_UnsupportedURL = NSURLErrorUnsupportedURL,
    SJMediaDownloadErrorCode_ConnectionWasLost = NSURLErrorNetworkConnectionLost,
    SJMediaDownloadErrorCode_NotConnectedToInternet = NSURLErrorNotConnectedToInternet,
};

@interface SJMediaEntity : NSObject <SJMediaEntity, NSCopying>
@property (nonatomic, assign) NSInteger mediaId;
@property (nonatomic, strong) NSString *URLStr;
@property (nonatomic, assign) SJMediaDownloadStatus downloadStatus;
@property (nonatomic, strong, nullable) NSString *title;
@property (nonatomic, strong, nullable) NSString *coverURLStr;
@property (nonatomic, assign) NSTimeInterval downloadTime;  // 插入数据库的时间
@property (nonatomic, assign) float downloadProgress;

@property (class, nonatomic, strong, readonly) NSString *rootFolder;
@property (class, nonatomic, assign) BOOL startNotifi;
@property (nonatomic, strong, readonly) NSURL *URL;
@property (nonatomic, weak, nullable) NSURLSessionDownloadTask *task;
@property (nonatomic, strong, readonly) NSString *URLHashStr;
- (void)postStatus;
- (void)postProgress;

@property (nonatomic, strong, nullable) NSString *relativePath;
@property (nonatomic, strong, readonly) NSString *resumePath;
@property (nonatomic, strong, readonly) NSString *format;

@end

@interface SJMediaDownloader (DownloadServer)<NSURLSessionDownloadDelegate>
@end

@interface NSURLSessionTask (SJDownloaderAdd)
@property (nonatomic, copy, nullable) void(^downloadProgressBlock)(__kindof NSURLSessionTask *task, float progress);;
@property (nonatomic, copy, nullable) void(^endDownloadHandleBlock)(__kindof NSURLSessionTask *task, NSURL *__nullable location, NSError *__nullable error);
@property (nonatomic, copy, nullable) void(^cancelledBlock)(void);
@end

@interface SJMediaDownloader ()
@property (nonatomic, strong, readwrite, nullable) SJMediaEntity *currentEntity;
@property (nonatomic, strong, readonly, nullable) SJMediaEntity *currentEntity_copy;
@property (nonatomic, strong, readonly) NSOperationQueue *taskQueue;
@property (nonatomic, strong, readonly) NSURLSession *downloadSession;
@property (nonatomic, assign, readonly) sqlite3 *database;
@end
NS_ASSUME_NONNULL_END

@implementation SJMediaDownloader

+ (instancetype)shared {
    static id _instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [self new];
    });
    return _instance;
}

- (instancetype)init {
    self = [super init];
    if ( !self ) return nil;
    [self initializeDatabase];
    [self installNotifications];
    [self checkoutRootFolder];
    return self;
}

- (void)checkoutRootFolder {
    NSString *rootFolder = [SJMediaEntity rootFolder];
    if ( ![[NSFileManager defaultManager] fileExistsAtPath:rootFolder] ) {
        [[NSFileManager defaultManager] createDirectoryAtPath:rootFolder withIntermediateDirectories:YES attributes:nil error:nil];
        [self addSkipBackupAttributeToItemAtPath:rootFolder]; // do not backup
    };
}

- (BOOL)addSkipBackupAttributeToItemAtPath:(NSString *)path {
    const char *filePath = [path fileSystemRepresentation];
    const char *attrName = "com.apple.MobileBackup";
    u_int8_t attrValue = 1;
    int result = setxattr(filePath, attrName, &attrValue, sizeof(attrValue), 0, 0);
    return result == 0;
}

- (void)startNotifier {
    SJMediaEntity.startNotifi = YES;
}

- (void)stopNotifier {
    SJMediaEntity.startNotifi = NO;
}

@synthesize taskQueue = _taskQueue;
- (NSOperationQueue *)taskQueue {
    if ( _taskQueue ) return _taskQueue;
    _taskQueue = [NSOperationQueue new];
    _taskQueue.maxConcurrentOperationCount = 1;
    _taskQueue.name = @"com.sjmediadownloader.taskqueue";
    return _taskQueue;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
- (void)async_requestMediasCompletion:(void(^)(SJMediaDownloader *downloader, NSArray<SJMediaEntity *> *medias))completionBlock {
    __weak typeof(self) _self = self;
    [self async_exeBlock:^{
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( completionBlock ) completionBlock(self, sql_query(self.database, "SELECT *FROM 'SJMediaEntity';", [SJMediaEntity class]));
    }];
}
- (void)async_requestMediaWithID:(NSInteger)mediaId
                      completion:(void(^)(SJMediaDownloader *downloader, SJMediaEntity *media))completionBlock {
    __weak typeof(self) _self = self;
    [self async_exeBlock:^{
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        NSString *sqlStr = [NSString stringWithFormat:@"SELECT *FROM 'SJMediaEntity' WHERE mediaId = %ld;", (long)mediaId];
        if ( completionBlock ) completionBlock(self, sql_query(self.database, sqlStr.UTF8String, [SJMediaEntity class]).firstObject);
    }];
}
- (void)async_requestMediasWithStatus:(SJMediaDownloadStatus)status
                           completion:(void(^)(SJMediaDownloader *downloader, NSArray<id<SJMediaEntity>> * __nullable medias))completionBlock {
    __weak typeof(self) _self = self;
    [self async_exeBlock:^{
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        NSString *sql = [NSString stringWithFormat:@"SELECT *FROM 'SJMediaEntity' WHERE downloadStatus = %ld ORDER BY downloadTime;", (long)status];
        if ( completionBlock ) completionBlock(self, sql_query(self.database, sql.UTF8String, [SJMediaEntity class]));
    }];
}
- (void)async_exeBlock:(void(^)(void))block {
    [self.taskQueue addOperationWithBlock:^{
        if ( block ) block();
    }];
}
- (void)sync_requestNextDownloadMedia {
    if ( self.currentEntity ) return;
    NSString *sql = [NSString stringWithFormat:@"SELECT *FROM 'SJMediaEntity' WHERE downloadStatus =  %ld ORDER BY downloadTime;", (long)SJMediaDownloadStatus_Waiting];
    SJMediaEntity *next = sql_query(self.database, sql.UTF8String, [SJMediaEntity class]).firstObject;
    if ( !next ) return;
    [self sync_downloadWithMedia:next];
}
- (void)sync_downloadWithMedia:(SJMediaEntity *)next {
    NSURLSessionDownloadTask *task = nil;
    NSData *resumeData = [NSData dataWithContentsOfFile:next.resumePath];
    if ( resumeData ) {
        task = [self.downloadSession downloadTaskWithResumeData:resumeData];
#if DEBUG_CONDITION
        NSLog(@"resume");
#endif
    }
    else {
        task = [self.downloadSession downloadTaskWithURL:next.URL];
#if DEBUG_CONDITION
        NSLog(@"new download");
#endif
    }
    
    [task resume];
    self.currentEntity = next;
    next.downloadStatus = SJMediaDownloadStatus_Downloading;
    [next postStatus];
    [self sync_insertOrReplaceMediaWithEntity:next];
    
    /// task
    next.task = task;
    
    __weak typeof(self) _self = self;
    task.downloadProgressBlock = ^(__kindof NSURLSessionTask * _Nonnull task, float progress) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        next.downloadProgress = progress;
        [next postProgress];
        [self sync_updateDownloadProgressWithEntity:next];
    };
    
    task.endDownloadHandleBlock = ^(NSURLSessionDownloadTask * _Nonnull task, NSURL * _Nullable location, NSError * _Nullable error) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
#if DEBUG_CONDITION
        if ( error ) {
            NSLog(@"Error ==> %@\n----- %zd", error, next.downloadStatus);
        }
#endif
        if ( location ) {
            NSString *folder = [NSString stringWithFormat:@"%@", next.URLHashStr];
            NSString *saveFolder = [[SJMediaEntity rootFolder] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@", folder]];
            NSString *savePath = [saveFolder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", next.URLHashStr, next.format]];
            [[NSFileManager defaultManager] createDirectoryAtPath:saveFolder withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:savePath error:nil];
            next.relativePath = [folder stringByAppendingPathComponent:savePath.lastPathComponent];
            next.downloadStatus = SJMediaDownloadStatus_Finished;
            [next postStatus];
            [self sync_insertOrReplaceMediaWithEntity:next];
            self.currentEntity = nil;
            [self sync_requestNextDownloadMedia];
        }
        else {
            __block SJMediaDownloadStatus status = SJMediaDownloadStatus_Unknown;
            void(^suspendExeBlock)(BOOL saved) = ^ (BOOL saved) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                if ( !saved ) {
                    next.downloadProgress = 0;
                    [next postProgress];
                }
                next.downloadStatus = status;
                [next postStatus];
                [self sync_insertOrReplaceMediaWithEntity:next];
                self.currentEntity = nil;
                [self sync_requestNextDownloadMedia];
            };
            
            switch ( (SJMediaDownloadErrorCode)error.code ) {
                case SJMediaDownloadErrorCode_Unknown: break;
                case SJMediaDownloadErrorCode_TimeOut: {
                    status = SJMediaDownloadErrorCode_TimeOut;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
                case SJMediaDownloadErrorCode_Cancelled: {
                    if ( task.cancelledBlock ) task.cancelledBlock();
                }
                    break;
                case SJMediaDownloadErrorCode_ConnectionWasLost: {
                    status = SJMediaDownloadStatus_ConnectionWasLost;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
                case SJMediaDownloadErrorCode_UnsupportedURL: {
                    status = SJMediaDownloadStatus_UnsupportedURL;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
                case SJMediaDownloadErrorCode_BadURL: {
                    status = SJMediaDownloadStatus_BadURL;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
                case SJMediaDownloadErrorCode_NotConnectedToInternet: {
                    status = SJMediaDownloadStatus_NotConnectedToInternet;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
                default: {
                    [[NSFileManager defaultManager] removeItemAtPath:next.resumePath error:nil];
                    status = SJMediaDownloadStatus_Failed;
                    [self async_suspendWithTask:task entity:next completion:suspendExeBlock];
                }
                    break;
            }
        }
    };
}
- (void)async_suspendWithTask:(NSURLSessionDownloadTask *)task entity:( SJMediaEntity *)entity completion:(void(^ __nullable)(BOOL saved))block {
    __weak typeof(self) _self = self;
    [task cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( resumeData ) {
            NSString *folder = [entity.resumePath stringByDeletingLastPathComponent];
            if ( ![[NSFileManager defaultManager] fileExistsAtPath:folder] ) {
                [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
            }
            [resumeData writeToFile:entity.resumePath atomically:YES];
        }
        [self async_exeBlock:^{
            if ( block ) block(resumeData != nil);
        }];
    }];
}
- (void)sync_insertOrReplaceMediaWithEntity:(SJMediaEntity *)entity {
    sql_exe(self.database, [NSString stringWithFormat:@"INSERT OR REPLACE INTO 'SJMediaEntity' VALUES (%ld, '%@', %ld, '%@', '%ld', '%@', %f);", (long)entity.mediaId, entity.title, (long)entity.downloadStatus, entity.URLStr, time(NULL), entity.relativePath, entity.downloadProgress].UTF8String);
}
- (void)sync_updateDownloadProgressWithEntity:(SJMediaEntity *)entity {
    NSString *sql = [NSString stringWithFormat:@"UPDATE 'SJMediaEntity' SET 'downloadProgress' = %f WHERE 'mediaId' = %ld;", entity.downloadProgress, (long)entity.mediaId];
    sql_exe(self.database, sql.UTF8String);
}
- (void)sync_deleteMediaWithEntity:(SJMediaEntity *)entity {
    sql_exe(self.database, [NSString stringWithFormat:@"DELETE FROM 'SJMediaEntity' WHERE mediaId = %ld;", (long)entity.mediaId].UTF8String);
}
- (void)initializeDatabase {
    sql_exe(self.database, "CREATE TABLE IF NOT EXISTS SJMediaEntity ('mediaId' INTEGER PRIMARY KEY, 'title' TEXT, 'downloadStatus' INTEGER, 'URLStr' TEXT, 'downloadTime' INTEGER, 'relativePath' TEXT, 'downloadProgress' FLOAT);");
}
@synthesize database = _database;
- (sqlite3 *)database {
    if ( _database ) return _database;
    NSString *folder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"com.sjmediadownloader.databasefolder"];
    if ( ![[NSFileManager defaultManager] fileExistsAtPath:folder] ) [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dbPath = [folder stringByAppendingPathComponent:@"mediaentity.db"];
    if ( SQLITE_OK != sqlite3_open(dbPath.UTF8String, &_database) ) NSLog(@"init database failed!");
    return _database;
}
#pragma clang diagnostic pop

#pragma mark - download
@synthesize downloadSession = _downloadSession;
- (NSURLSession *)downloadSession {
    if ( _downloadSession ) return _downloadSession;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:self.taskQueue];
    return _downloadSession;
}

- (void)async_downloadWithID:(NSInteger)mediaId title:(NSString * __nullable)title mediaURLStr:(NSString *)mediaURLStr {
    __weak typeof(self) _self = self;
    [self async_requestMediaWithID:mediaId completion:^(SJMediaDownloader * _Nonnull downloader, SJMediaEntity * media) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        if ( media.downloadStatus == SJMediaDownloadStatus_Finished ) return;
        if ( media.downloadStatus == SJMediaDownloadStatus_Waiting && self.currentEntity ) return;
        if ( media.downloadStatus == SJMediaDownloadStatus_Downloading && self.currentEntity.mediaId == media.mediaId ) return;
        
        if ( !media ) {
            media = [SJMediaEntity new];
            media.mediaId = mediaId;
            media.title = title;
            media.URLStr = mediaURLStr;
            media.downloadStatus = SJMediaDownloadStatus_Waiting;
            [media postStatus];
            [self sync_insertOrReplaceMediaWithEntity:media];
        }
        else if ( media.downloadStatus != SJMediaDownloadStatus_Finished ) {
            if ( media.downloadStatus == SJMediaDownloadStatus_UnsupportedURL ) media.URLStr = mediaURLStr;
            media.downloadStatus = SJMediaDownloadStatus_Waiting;
            [media postStatus];
            [self sync_insertOrReplaceMediaWithEntity:media];
        }
        
        if ( !self.currentEntity ) [self sync_downloadWithMedia:media];
    }];
}

- (void)async_pauseWithMediaID:(NSInteger)mediaId completion:(void(^)(void))block {
    __weak typeof(self) _self = self;
    [self async_exeBlock:^{
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        __block SJMediaEntity *entity = nil;
        void(^pausedBlock)(void) = ^ {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( entity.downloadStatus == SJMediaDownloadStatus_Paused ) {
                if ( block ) block();
            }
            else if ( entity.downloadStatus == SJMediaDownloadStatus_Finished ) {
                NSLog(@"文件已下载, 无法暂停");
            }
            else {
                entity.downloadStatus = SJMediaDownloadStatus_Paused;
                [entity postStatus];
                [self sync_insertOrReplaceMediaWithEntity:entity];
                if ( entity.mediaId == self.currentEntity.mediaId ) self.currentEntity = nil;
                if ( block ) block();
            }
            [self sync_requestNextDownloadMedia];
        };
        
        
        if ( self.currentEntity.task && self.currentEntity.mediaId == mediaId && self.currentEntity.downloadStatus == SJMediaDownloadStatus_Downloading ) {
            entity = self.currentEntity;
            if ( self.currentEntity.task.state != NSURLSessionTaskStateCanceling ) {
                self.currentEntity.task.cancelledBlock = pausedBlock;
                [self async_suspendWithTask:self.currentEntity.task entity:self.currentEntity completion:^(BOOL saved) {}];
            }
            else {
                pausedBlock();
            }
        }
        else {
            [self async_requestMediaWithID:mediaId completion:^(SJMediaDownloader * _Nonnull downloader, SJMediaEntity *media) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                entity = media;
                pausedBlock();
            }];
        }
    }];
}

- (void)async_pauseAllDownloadsCompletion:(void(^ __nullable)(void))block {
    __weak typeof(self) _self = self;
    [self async_requestMediasWithStatus:SJMediaDownloadStatus_Waiting completion:^(SJMediaDownloader * _Nonnull downloader, NSArray<id<SJMediaEntity>> * _Nullable medias) {
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        [medias enumerateObjectsUsingBlock:^(SJMediaEntity *obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if ( obj.mediaId != self.currentEntity.mediaId ) {
                if ( obj.downloadStatus != SJMediaDownloadStatus_Paused &&
                    obj.downloadStatus != SJMediaDownloadStatus_Finished ) {
                    obj.downloadStatus = SJMediaDownloadStatus_Paused;
                    [obj postStatus];
                    [self sync_insertOrReplaceMediaWithEntity:obj];
                }
            }
        }];
        [self async_pauseWithMediaID:self.currentEntity.mediaId completion:block];
    }];
}

- (void)async_deleteWithMediaID:(NSInteger)mediaId completion:(void(^)(void))block {
    __weak typeof(self) _self = self;
    [self async_exeBlock:^{
        __strong typeof(_self) self = _self;
        if ( !self ) return;
        
        __block SJMediaEntity *entity = nil;
        void(^deleted)(void) = ^ {
            __strong typeof(_self) self = _self;
            if ( !self ) return;
            if ( [[NSFileManager defaultManager] fileExistsAtPath:entity.filePath] ) {
                [[NSFileManager defaultManager] removeItemAtPath:[entity.filePath stringByDeletingLastPathComponent] error:nil];
            }
            if ( [[NSFileManager defaultManager] fileExistsAtPath:entity.resumePath] ) {
                [[NSFileManager defaultManager] removeItemAtPath:entity.resumePath error:nil];
            }
            entity.downloadStatus = SJMediaDownloadStatus_Deleted;
            [entity postStatus];
            entity.downloadProgress = 0;
            [entity postProgress];
            [self sync_deleteMediaWithEntity:entity];
            if ( entity == self.currentEntity ) self.currentEntity = nil;
            if ( block ) block();
        };
        
        if ( self.currentEntity && self.currentEntity.mediaId == mediaId ) {
            if ( self.currentEntity.task ) {
                entity = self.currentEntity;
                self.currentEntity.task.cancelledBlock = deleted;
                [self.currentEntity.task cancel];
            }
            else {
                entity = self.currentEntity;
                deleted();
            }
        }
        else {
            [self async_requestMediaWithID:mediaId completion:^(SJMediaDownloader * _Nonnull downloader, SJMediaEntity *media) {
                __strong typeof(_self) self = _self;
                if ( !self ) return;
                entity = media;
                deleted();
            }];
        }
    }];
}
#pragma mark -


#pragma mark -
- (unsigned long long)fileSize {
    __block unsigned long long size = 0;
    NSString *rootFolder = [SJMediaEntity rootFolder];
    [[[NSFileManager defaultManager] subpathsAtPath:rootFolder] enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        size += [[NSFileManager defaultManager] attributesOfItemAtPath:[rootFolder stringByAppendingPathComponent:obj] error:nil].fileSize;
    }];
    return size;
}

#pragma mark -
- (void)installNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate) name:UIApplicationWillTerminateNotification object:nil];
}

- (void)applicationWillTerminate {
    [_downloadSession invalidateAndCancel];
    if ( _currentEntity.downloadStatus != SJMediaDownloadStatus_Finished ) {
        self.currentEntity_copy.downloadStatus = SJMediaDownloadStatus_Paused;
        [self sync_insertOrReplaceMediaWithEntity:self.currentEntity_copy];
    }
}

@synthesize currentEntity_copy = _currentEntity_copy;
- (void)setCurrentEntity:(SJMediaEntity *)currentEntity {
    _currentEntity = currentEntity;
    _currentEntity_copy = currentEntity.copy;
}
@end

@implementation SJMediaDownloader (DownloadServer)
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    float progress = 1.0 * totalBytesWritten / totalBytesExpectedToWrite;
    if ( downloadTask.downloadProgressBlock ) downloadTask.downloadProgressBlock(downloadTask, progress);
}
- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location {
    if ( downloadTask.endDownloadHandleBlock ) downloadTask.endDownloadHandleBlock(downloadTask, location, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if ( error ) if ( task.endDownloadHandleBlock ) task.endDownloadHandleBlock(task, nil, error);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
#if DEBUG_CONDITION
    NSLog(@"\nmediaId:%zd \noffset: %zd \ntotal: %zd", self.currentEntity.mediaId, fileOffset, expectedTotalBytes);
#endif
}
@end

@implementation NSURLSessionTask (SJDownloaderAdd)
- (void)setDownloadProgressBlock:(void (^ __nullable)(__kindof NSURLSessionTask * _Nonnull, float))downloadProgressBlock {
    objc_setAssociatedObject(self, @selector(downloadProgressBlock), downloadProgressBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void (^ __nullable)(__kindof NSURLSessionTask * _Nonnull, float))downloadProgressBlock {
    return objc_getAssociatedObject(self, _cmd);
}
- (void)setEndDownloadHandleBlock:(void (^__nullable)(__kindof NSURLSessionTask * _Nonnull, NSURL * _Nullable, NSError * _Nullable))endDownloadHandleBlock {
    objc_setAssociatedObject(self, @selector(endDownloadHandleBlock), endDownloadHandleBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void (^__nullable)(__kindof NSURLSessionTask * _Nonnull, NSURL * _Nullable, NSError * _Nullable))endDownloadHandleBlock {
    return objc_getAssociatedObject(self, _cmd);
}
- (void)setCancelledBlock:(void (^)(void))cancelledBlock {
    objc_setAssociatedObject(self, @selector(cancelledBlock), cancelledBlock, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void (^__nullable)(void))cancelledBlock {
    return objc_getAssociatedObject(self, _cmd);
}
@end

@implementation SJMediaEntity
@synthesize downloadStatus = _downloadStatus;
@synthesize mediaId = _mediaId;
@synthesize URLStr = _URLStr;
@synthesize filePath = _filePath;
@synthesize URLHashStr = _URLHashStr;
- (NSString *)URLHashStr {
    if ( !_URLStr ) return nil;
    if ( _URLHashStr ) return _URLHashStr;
    _URLHashStr = [NSString stringWithFormat:@"%ld", (long)[_URLStr hash]];
    return _URLHashStr;
}
- (NSString *)format {
    if ( _URLStr.pathExtension.length != 0 )  return _URLStr.pathExtension;
    else return @"mp4";
}
@synthesize URL = _URL;
- (NSURL *)URL {
    if ( !_URLStr ) return nil;
    if ( _URL ) return _URL;
    _URL = [NSURL URLWithString:_URLStr];
    return _URL;
}
@synthesize resumePath = _resumePath;
- (NSString *)resumePath {
    if ( _resumePath ) return _resumePath;
    _resumePath = [NSTemporaryDirectory() stringByAppendingPathComponent:self.URLHashStr];
    return _resumePath;
}
- (NSString *)filePath {
    if ( !_relativePath ) return nil;
    if ( _filePath ) return _filePath;
    _filePath = [[SJMediaEntity rootFolder] stringByAppendingPathComponent:_relativePath];
    return _filePath;
}
+ (NSString *)rootFolder {
    NSString *rootFolder = objc_getAssociatedObject(self, _cmd);
    if ( rootFolder ) return rootFolder;
    rootFolder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent:@"sj_downloader_root_folder"];
    objc_setAssociatedObject(self, _cmd, rootFolder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return rootFolder;
}
+ (void)setStartNotifi:(BOOL)startNotifi {
    objc_setAssociatedObject(self, @selector(startNotifi), @(startNotifi), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
+ (BOOL)startNotifi {
    return [objc_getAssociatedObject(self, _cmd) boolValue];
}
- (void)postStatus {
    if ( [SJMediaEntity startNotifi] ) [[NSNotificationCenter defaultCenter] postNotificationName:SJMediaDownloadStatusChangedNotification object:self];
}
- (void)postProgress {
    if ( [SJMediaEntity startNotifi] ) [[NSNotificationCenter defaultCenter] postNotificationName:SJMediaDownloadProgressNotification object:self];
}
- (id)copyWithZone:(NSZone *)zone {
    SJMediaEntity *new = [SJMediaEntity new];
    [ivar_list([self class]) enumerateObjectsUsingBlock:^(NSString * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        [new setValue:[self valueForKey:obj] forKey:obj];
    }];
    return new;
}
static NSArray<NSString *> *ivar_list(Class cls) {
    NSMutableArray *invarListArrM = [NSMutableArray array];
    unsigned int outCount = 0;
    Ivar *ivarList = class_copyIvarList(cls, &outCount);
    if (ivarList != NULL && outCount > 0) {
        for (int i = 0; i < outCount; i ++) {
            const char *name = ivar_getName(ivarList[i]);
            NSString *nameStr = [NSString stringWithUTF8String:name];
            [invarListArrM addObject:nameStr];
        }
    }
    free(ivarList);
    return invarListArrM;
}

@end

static NSArray <id> *sql_data(sqlite3_stmt *stmt, Class cls);
inline static bool sql_exe(sqlite3 *database, const char *sql) {
    char *error = NULL;
    bool r = (SQLITE_OK == sqlite3_exec(database, sql, NULL, NULL, &error));
    if ( error != NULL ) { NSLog(@"Error ==> \n SQL  : %s\n Error: %s", sql, error); sqlite3_free(error);}
    return r;
}
inline static NSArray<id> *sql_query(sqlite3 *database, const char *sql, Class cls) {
    sqlite3_stmt *pstmt;
    int result = sqlite3_prepare_v2(database, sql, -1, &pstmt, NULL);
    NSArray <NSDictionary *> *dataArr = nil;
    if (SQLITE_OK == result) dataArr = sql_data(pstmt, cls);
    sqlite3_finalize(pstmt);
    return dataArr;
}
static NSArray <id> *sql_data(sqlite3_stmt *stmt, Class cls) {
    NSMutableArray *dataArrM = [[NSMutableArray alloc] init];
    while ( sqlite3_step(stmt) == SQLITE_ROW ) {
        id model = [cls new];
        int columnCount = sqlite3_column_count(stmt);
        for ( int i = 0; i < columnCount ; ++ i ) {
            const char *c_key = sqlite3_column_name(stmt, i);
            NSString *oc_key = [NSString stringWithCString:c_key encoding:NSUTF8StringEncoding];
            int type = sqlite3_column_type(stmt, i);
            switch (type) {
                case SQLITE_INTEGER: {
                    int value = sqlite3_column_int(stmt, i);
                    [model setValue:@(value) forKey:oc_key];
                }
                    break;
                case SQLITE_TEXT: {
                    const  char *value = (const  char *)sqlite3_column_text(stmt, i);
                    [model setValue:[NSString stringWithUTF8String:value] forKey:oc_key];
                }
                    break;
                case SQLITE_FLOAT: {
                    double value = sqlite3_column_double(stmt, i);
                    [model setValue:@(value) forKey:oc_key];
                }
                    break;
                default:
                    break;
            }
        }
        [dataArrM addObject:model];
    }
    if ( dataArrM.count == 0 ) return nil;
    return dataArrM.copy;
}

NSNotificationName const SJMediaDownloadProgressNotification = @"SJMediaDownloadProgressNotification";
NSString *const kSJMediaDownloadProgressKey = @"kSJMediaDownloadProgressKey";
NSNotificationName const SJMediaDownloadStatusChangedNotification = @"SJMediaDownloadStatusChangedNotification";
