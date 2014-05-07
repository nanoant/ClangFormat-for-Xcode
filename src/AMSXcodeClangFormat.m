//
// AMSXcodeClangFormat.m
// AMSXcodeClangFormat
//
// Copyright (c) 2014 Adam Strzelecki
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "AMSXcodeClangFormat.h"
#import <objc/runtime.h>

#define PLUGIN @"AMSXcodeClangFormat"

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Portions of Xcode interface

@interface DVTSourceCodeLanguage : NSObject
- (NSString *)identifier;
@end

@interface DVTFilePath : NSObject
- (void)_notifyAssociatesOfChange;
@end

@interface XCSourceModel : NSObject
- (BOOL)isInStringConstantAtLocation:(NSUInteger)index;
@end

@interface NSTextStorage (AMSXcodeClangFormat_DVTSourceTextStorage)
- (void)replaceCharactersInRange:(NSRange)range
                      withString:(NSString *)string
                 withUndoManager:(id)undoManager;
- (NSRange)lineRangeForCharacterRange:(NSRange)range;
- (NSRange)characterRangeForLineRange:(NSRange)range;
- (void)indentCharacterRange:(NSRange)range undoManager:(id)undoManager;
- (DVTSourceCodeLanguage *)language;
- (XCSourceModel *)sourceModel;
@end

@interface NSDocument (AMSXcodeClangFormat_IDESourceCodeDocument)
- (NSUndoManager *)undoManager;
- (NSTextStorage *)textStorage;
- (void)_respondToFileChangeOnDiskWithFilePath:(DVTFilePath *)filePath;
- (DVTFilePath *)filePath;
- (void)ide_revertDocumentToSaved:(id)sender;
@end

@interface NSTextView (AMSXcodeClangFormat_DVTSourceTextView)
- (BOOL)isInlineCompleting;
@end

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Default settings

static NSSet *SupportedLanguages = nil;

static NSString *ClangFormatPath = nil;
static NSString *ClangFormatStyle = nil;

static NSString *DefaultClangFormatPath = nil;
static NSString *DefaultClangFormatStyle = @"file";

static NSArray *ClangFormatArguments = nil;
static NSArray *DefaultClangFormatArguments = nil;

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Clang-format on-save

@implementation NSDocument (AMSXcodeClangFormat)
- (void)AMSXcodeClangFormat_saveDocumentWithDelegate:(id)delegate
                                     didSaveSelector:(SEL)didSaveSelector
                                         contextInfo:(void *)contextInfo
{
  if (!delegate) {
    delegate = self;
    didSaveSelector =
        @selector(AMSXcodeClangFormat_document:didSave:contextInfo:);
  }
  [self AMSXcodeClangFormat_saveDocumentWithDelegate:delegate
                                     didSaveSelector:didSaveSelector
                                         contextInfo:contextInfo];
}

- (void)AMSXcodeClangFormat_document:(NSDocument *)document
                             didSave:(BOOL)didSave
                         contextInfo:(void *)contextInfo
{
  if ([self respondsToSelector:@selector(textStorage)]) {
    NSTextStorage *textStorage = [self textStorage];
    if ([textStorage respondsToSelector:@selector(language)]) {
      NSString *language = [[textStorage language] identifier];
      if (didSave && [ClangFormatPath length] &&
          [SupportedLanguages containsObject:language]) {
        [self performSelectorInBackground:@selector(
                                              AMSXcodeClangFormat_clangFormat:)
                               withObject:ClangFormatPath];
      }
    }
  }
}

- (void)AMSXcodeClangFormat_clangFormat:(NSString *)clangFormatPath
{
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSString *path = [[self fileURL] path];

  NSData *beforeData = [NSData dataWithContentsOfFile:path];
  NSDictionary *before = [fileManager attributesOfItemAtPath:path error:NULL];

  NSTask *task = [[NSTask alloc] init];
  task.launchPath = clangFormatPath;
  task.arguments = @[
    @"-i",
    [NSString stringWithFormat:@"-style=%@", ClangFormatStyle],
    path
  ];
  // prepend extra arguments if they are available
  if (ClangFormatArguments.count) {
    task.arguments =
        [ClangFormatArguments arrayByAddingObjectsFromArray:task.arguments];
  }

#if DEBUG
  NSLog(@"launch: %@%@", clangFormatPath,
        [task.arguments componentsJoinedByString:@" "]);
#endif
  [task launch];
  [task waitUntilExit];
  [task release];

  NSDictionary *after = [fileManager attributesOfItemAtPath:path error:NULL];
  NSData *afterData = [NSData dataWithContentsOfFile:path];

  // this is workaround for Xcode not reloading file if modification date
  // is the same as saved one, which can happen if we reformat in same second.
  if (![afterData isEqualToData:beforeData] && before &&
      [after.fileModificationDate isEqualToDate:before.fileModificationDate]) {
    NSDictionary *attributes = [NSDictionary
        dictionaryWithObjectsAndKeys:[after.fileModificationDate
                                         dateByAddingTimeInterval:1],
                                     NSFileModificationDate, nil];
    [fileManager setAttributes:attributes ofItemAtPath:path error:NULL];
  }
}

@end

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Plugin startup

static BOOL Swizzle(Class class, SEL original, SEL replacement)
{
  if (!class) return NO;
  Method originalMethod = class_getInstanceMethod(class, original);
  if (!originalMethod) {
    NSLog(PLUGIN @" error: original method -[%@ %@] not found",
          NSStringFromClass(class), NSStringFromSelector(original));
    return NO;
  }
  Method replacementMethod = class_getInstanceMethod(class, replacement);
  if (!replacementMethod) {
    NSLog(PLUGIN @" error: replacement method -[%@ %@] not found",
          NSStringFromClass(class), NSStringFromSelector(replacement));
    return NO;
  }
  method_exchangeImplementations(originalMethod, replacementMethod);
  return YES;
}

@implementation AMSXcodeClangFormat
+ (void)pluginDidLoad:(NSBundle *)bundle
{
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];

  // Xcode 4 support
  if (![bundleIdentifier isEqualToString:@"com.apple.dt.Xcode"]) {
    if (bundleIdentifier.length) {
      // complain only when there's bundle identifier
      NSLog(PLUGIN @" unknown bundle identifier: %@", bundleIdentifier);
    }
    return;
  }
  Swizzle(NSClassFromString(@"IDESourceCodeDocument"),
          @selector(saveDocumentWithDelegate:didSaveSelector:contextInfo:),
          @selector(AMSXcodeClangFormat_saveDocumentWithDelegate:
                                                 didSaveSelector:
                                                     contextInfo:));
  SupportedLanguages = [[NSSet alloc]
      initWithObjects:@"Xcode.SourceCodeLanguage.C", // Xcode 4
                      @"Xcode.SourceCodeLanguage.C++",
                      @"Xcode.SourceCodeLanguage.C-Plus-Plus",
                      @"Xcode.SourceCodeLanguage.Objective-C",
                      @"Xcode.SourceCodeLanguage.Objective-C++",
                      @"Xcode.SourceCodeLanguage.Objective-C-Plus-Plus",
                      @"Xcode.SourceCodeLanguage.Objective-J",
                      @"Xcode.SourceCodeLanguage.JavaScript", nil];
#if DEBUG
  NSLog(PLUGIN @" %@ loaded.",
        [[NSBundle mainBundle]
            objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey]);
#endif

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  [self userDefaultsDidChange:
            [NSNotification
                notificationWithName:NSUserDefaultsDidChangeNotification
                              object:userDefaults]];

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(userDefaultsDidChange:)
                 name:NSUserDefaultsDidChangeNotification
               object:userDefaults];
}

#define LOAD_DEFAULT(clazz, name)                                              \
  if ((ovalue = [userDefaults objectForKey:@"AMS" @ #name]) &&                 \
      [ovalue isKindOfClass:[clazz class]]) {                                  \
    if (!name || ![name isEqual:ovalue]) {                                     \
      [name release];                                                          \
      name = [ovalue copy];                                                    \
    }                                                                          \
  } else if (![name isEqual:Default##name]) {                                  \
    [name release];                                                            \
    name = [Default##name copy];                                               \
  }

+ (void)userDefaultsDidChange:(NSNotification *)notification
{
  NSUserDefaults *userDefaults = (NSUserDefaults *)[notification object];

  NSString *ovalue;
  LOAD_DEFAULT(NSString, ClangFormatPath);
  LOAD_DEFAULT(NSString, ClangFormatStyle);
  LOAD_DEFAULT(NSArray, ClangFormatArguments);
}

@end
