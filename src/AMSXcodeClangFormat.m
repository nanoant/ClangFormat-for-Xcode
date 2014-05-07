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

@interface NSTextStorage (AMSXcodeClangFormat_DVTSourceTextStorage)
- (void)replaceCharactersInRange:(NSRange)range
                      withString:(NSString *)string
                 withUndoManager:(id)undoManager;
- (DVTSourceCodeLanguage *)language;
@end

@interface NSDocument (AMSXcodeClangFormat_IDESourceCodeDocument)
- (NSUndoManager *)undoManager;
- (NSTextStorage *)textStorage;
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
  if ([self respondsToSelector:@selector(textStorage)]) {
    NSTextStorage *textStorage = [self textStorage];
    if ([textStorage respondsToSelector:@selector(language)]) {
      NSString *language = [[textStorage language] identifier];
      if ([ClangFormatPath length] &&
          [SupportedLanguages containsObject:language]) {
        [self AMSXcodeClangFormat_format];
      }
    }
  }
  [self AMSXcodeClangFormat_saveDocumentWithDelegate:delegate
                                     didSaveSelector:didSaveSelector
                                         contextInfo:contextInfo];
}

- (void)AMSXcodeClangFormat_format
{
  NSString *path = [[self fileURL] path];
  NSPipe *input = [[NSPipe alloc] init];
  NSPipe *output = [[NSPipe alloc] init];
  NSTask *task = [[NSTask alloc] init];
  task.launchPath = ClangFormatPath;
  task.arguments = @[
    @"-output-replacements-xml",
    [NSString stringWithFormat:@"-assume-filename=%@", path],
    [NSString stringWithFormat:@"-style=%@", ClangFormatStyle]
  ];
  task.standardInput = input;
  task.standardOutput = output;
  // prepend extra arguments if they are available
  if (ClangFormatArguments.count) {
    task.arguments =
        [ClangFormatArguments arrayByAddingObjectsFromArray:task.arguments];
  }

#if DEBUG
  NSLog(@"launch: %@%@", ClangFormatPath,
        [task.arguments componentsJoinedByString:@" "]);
#endif
  [task launch];
  [input.fileHandleForWriting
      writeData:[self.textStorage.string
                    dataUsingEncoding:NSUTF8StringEncoding]];
  [input.fileHandleForWriting closeFile];
  NSData *data = [output.fileHandleForReading readDataToEndOfFile];
  AMSXcodeClangFormat *clangFormat =
      [[AMSXcodeClangFormat alloc] initWithDocument:self replacementData:data];
  [clangFormat format];
  [clangFormat release];
  [task release];
  [input release];
  [output release];
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

@interface AMSXcodeClangFormat () {
  NSDocument *_document;
  NSData *_data;
  NSRange _replacementRange;
  NSMutableString *_replacement;
  NSInteger offsetDiff;
}
@end

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

- (instancetype)initWithDocument:(NSDocument *)document
                 replacementData:(NSData *)data
{
  if ((self = [super init])) {
    _document = [document retain];
    _data = [data retain];
  }
  return self;
}

- (void)format
{
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:_data];
  parser.delegate = self;
  [parser parse];
  [parser release];
}

#pragma mark - XML parser delegate

- (void)parserDidStartDocument:(NSXMLParser *)parser
{
#if DEBUG
  NSLog(PLUGIN @" start format");
#endif
  [_document.undoManager beginUndoGrouping];
  _replacementRange.location = NSNotFound;
}

- (void)parserDidEndDocument:(NSXMLParser *)parser
{
#if DEBUG
  NSLog(PLUGIN @" end format");
#endif
  [_document.undoManager endUndoGrouping];
}

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary *)attributeDict
{
  if (![elementName isEqualToString:@"replacement"]) return;

  NSString *offsetText = [attributeDict valueForKey:@"offset"];
  NSString *lengthText = [attributeDict valueForKey:@"length"];
  if (offsetText && lengthText) {
    _replacementRange.location = [offsetText integerValue];
    _replacementRange.length = [lengthText integerValue];
  }
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName
{
  if (_replacementRange.location != NSNotFound) {
    NSString *replacement = _replacement ?: @"";
    _replacementRange.location = (NSInteger)_replacementRange.location + //
                                 offsetDiff;
    offsetDiff += (NSInteger)_replacement.length - //
                  (NSInteger)_replacementRange.length;
    [_document.textStorage replaceCharactersInRange:_replacementRange
                                         withString:replacement
                                    withUndoManager:_document.undoManager];
#if DEBUG
    NSLog(PLUGIN @" replace: %lu [%lu] with: '%@'",
          (unsigned long)_replacementRange.location,
          (unsigned long)_replacementRange.length, replacement);
#endif
  }
  _replacementRange.location = NSNotFound;
  [_replacement release], _replacement = nil;
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  if (_replacementRange.location == NSNotFound || !string.length) return;

  if (!_replacement) {
    _replacement = [[NSMutableString alloc] initWithString:string];
  } else {
    [_replacement appendString:string];
  }
}

- (void)dealloc
{
  [super dealloc];
  [_replacement release];
  [_document release];
  [_data release];
}

@end
