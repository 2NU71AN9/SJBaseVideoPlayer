#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "SJBaseVideoPlayer+TestLog.h"
#import "SJBaseVideoPlayer.h"
#import "SJPlaybackRecordSaveHandler.h"
#import "UIScrollView+ListViewAutoplaySJAdd.h"
#import "AVAsset+SJAVMediaExport.h"
#import "SJAVMediaPlayer.h"
#import "SJAVMediaPlayerLayerView.h"
#import "SJAVMediaPlayerLoader.h"
#import "SJAVPictureInPictureController.h"
#import "SJVideoPlayerURLAsset+SJAVMediaPlaybackAdd.h"
#import "SJVideoPlayerURLAssetPrefetcher.h"
#import "SJAVMediaPlaybackController.h"
#import "SJAliMediaPlayer.h"
#import "SJAliMediaPlayerLayerView.h"
#import "SJVideoPlayerURLAsset+SJAliMediaPlaybackAdd.h"
#import "SJAliMediaPlaybackController.h"
#import "SJBaseVideoPlayerConst.h"
#import "SJVideoPlayerPlayStatusDefines.h"
#import "NSString+SJBaseVideoPlayerExtended.h"
#import "NSTimer+SJAssetAdd.h"
#import "SJControlLayerAppearStateManager.h"
#import "SJDanmakuItem.h"
#import "SJDanmakuPopupController.h"
#import "SJDeviceVolumeAndBrightnessManager.h"
#import "SJFitOnScreenManager.h"
#import "SJFlipTransitionManager.h"
#import "SJMediaPlaybackController.h"
#import "SJPlaybackHistoryController.h"
#import "SJPlaybackObservation.h"
#import "SJPlaybackRecord.h"
#import "SJPlayerAutoplayConfig.h"
#import "SJPlayerView.h"
#import "SJPlayerViewInternal.h"
#import "SJPlayModel+SJPrivate.h"
#import "SJPlayModel.h"
#import "SJPlayModelPropertiesObserver.h"
#import "SJPromptingPopupController.h"
#import "SJReachability.h"
#import "SJRotationDefines.h"
#import "SJRotationFullscreenNavigationController.h"
#import "SJRotationFullscreenViewController.h"
#import "SJRotationFullscreenWindow.h"
#import "SJRotationManager.h"
#import "SJRotationManagerInternal.h"
#import "SJRotationManager_iOS_16_Later.h"
#import "SJRotationManager_iOS_9_15.h"
#import "SJRotationObserver.h"
#import "SJSmallViewFloatingController.h"
#import "SJSubtitleItem.h"
#import "SJSubtitlePopupController.h"
#import "SJTextPopupController.h"
#import "SJVideoDefinitionSwitchingInfo+Private.h"
#import "SJVideoDefinitionSwitchingInfo.h"
#import "SJVideoPlayerPresentView.h"
#import "SJVideoPlayerURLAsset+SJSubtitlesAdd.h"
#import "SJVideoPlayerURLAsset.h"
#import "SJViewControllerManager.h"
#import "SJWatermarkView.h"
#import "SJControlLayerAppearManagerDefines.h"
#import "SJDanmakuPopupControllerDefines.h"
#import "SJDeviceVolumeAndBrightnessManagerDefines.h"
#import "SJFitOnScreenManagerDefines.h"
#import "SJFlipTransitionManagerDefines.h"
#import "SJGestureControllerDefines.h"
#import "SJPictureInPictureControllerDefines.h"
#import "SJPlaybackHistoryControllerDefines.h"
#import "SJPromptingPopupControllerDefines.h"
#import "SJReachabilityDefines.h"
#import "SJRotationManagerDefines.h"
#import "SJSmallViewFloatingControllerDefines.h"
#import "SJSubtitlePopupControllerDefines.h"
#import "SJTextPopupControllerDefines.h"
#import "SJVideoPlayerControlLayerProtocol.h"
#import "SJVideoPlayerPlaybackControllerDefines.h"
#import "SJVideoPlayerPresentViewDefines.h"
#import "SJViewControllerManagerDefines.h"
#import "SJWatermarkViewDefines.h"
#import "CALayer+SJBaseVideoPlayerExtended.h"
#import "UIScrollView+SJBaseVideoPlayerExtended.h"
#import "UIView+SJBaseVideoPlayerExtended.h"
#import "UIViewController+SJBaseVideoPlayerExtended.h"
#import "SJTimerControl.h"
#import "SJVideoPlayerRegistrar.h"
#import "SJBaseVideoPlayerResourceLoader.h"

FOUNDATION_EXPORT double SJBaseVideoPlayerVersionNumber;
FOUNDATION_EXPORT const unsigned char SJBaseVideoPlayerVersionString[];

