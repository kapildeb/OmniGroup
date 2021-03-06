// Copyright 2002-2008, 2010-2012 Omni Development, Inc. All rights reserved.
//
// This software may only be used and reproduced according to the
// terms in the file OmniSourceLicense.html, which should be
// distributed with this project and can also be found at
// <http://www.omnigroup.com/developer/sourcecode/sourcelicense/>.

#import "OIInspectorController.h"

#import <AppKit/AppKit.h>
#import <OmniFoundation/OmniFoundation.h>
#import <OmniBase/OmniBase.h>

#import "OIInspector.h"
#import "OIInspectorGroup.h"
#import "OIInspectorHeaderView.h"
#import "OIInspectorHeaderBackground.h"
#import "OIInspectorRegistry.h"
#import "OIInspectorResizer.h"
#import "OIInspectorWindow.h"

#import <OmniAppKit/NSImage-OAExtensions.h>
#import <OmniAppKit/NSString-OAExtensions.h>

#include <sys/sysctl.h>

RCS_ID("$Id$");

NSString * const OIInspectorControllerDidChangeExpandednessNotification = @"OIInspectorControllerDidChangeExpandedness";

@interface OIInspectorController (/*Private*/) <OIInspectorHeaderViewDelegateProtocol>

@property (nonatomic, assign) OIInspectorInterfaceType interfaceType;
@property (nonatomic, strong) NSView *embeddedContainerView;

- (void)_buildHeadingView;
- (void)_buildWindow;
- (void)_populateContainerView;

- (NSView *)_inspectorView;
- (void)_setFloatingExpandedness:(BOOL)expanded updateInspector:(BOOL)updateInspector withNewTopLeftPoint:(NSPoint)topLeftPoint animate:(BOOL)animate;
- (void)_setEmbeddedExpandedness:(BOOL)expanded updateInspector:(BOOL)updateInspector;
- (void)_postExpandednessChangedNotification;
- (void)_saveInspectorHeight;

- (BOOL)_groupCanBeginResizingOperation;

@end

NSComparisonResult sortByDefaultDisplayOrderInGroup(OIInspectorController *a, OIInspectorController *b, void *context)
{
    NSUInteger aOrder = [[a inspector] defaultOrderingWithinGroup];
    NSUInteger bOrder = [[b inspector] defaultOrderingWithinGroup];
    
    if (aOrder < bOrder)
        return NSOrderedAscending;
    else if (aOrder > bOrder)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

@implementation OIInspectorController

// Init and dealloc

static BOOL animateInspectorToggles;

+ (void)initialize;
{
    NSNumber *number;
    
    OBINITIALIZE;
    
    number = [[NSUserDefaults standardUserDefaults] objectForKey:@"AnimateInspectorToggles"];
    if (number) {
        animateInspectorToggles = [number boolValue];
    } else {
        /* Take a guess as to whether we should animate. If we have multiple cores, we're on a fast-ish machine. */
        static const int hw_activecpu[] = { CTL_HW, HW_AVAILCPU };
        int ncpu;
        size_t bufsize = sizeof(ncpu);
        
        if(sysctl((int *)hw_activecpu, sizeof(hw_activecpu)/sizeof(hw_activecpu[0]), &ncpu, &bufsize, NULL, 0) == 0 &&
           bufsize == sizeof(ncpu)) {
            animateInspectorToggles = ( ncpu > 1 ) ? YES : NO;
        } else {
            perror("sysctl(hw.activecpu)");
            animateInspectorToggles = NO;
        }
    }
}

- (id)initWithInspector:(OIInspector *)anInspector;
{
    if (!(self = [super init]))
        return nil;

    inspector = [anInspector retain];
    isExpanded = NO;
    self.interfaceType = anInspector.preferredInterfaceType;
    
    if ([inspector respondsToSelector:@selector(setInspectorController:)])
        [(id)inspector setInspectorController:self];
    
    return self;
}

// API

- (void)setGroup:(OIInspectorGroup *)aGroup;
{
    if (group != aGroup) {
        group = aGroup;
        if (group != nil)
            [headingButton setNeedsDisplay:YES];
    }
}

- (OIInspector *)inspector;
{
    return inspector;
}

- (NSWindow *)window;
{
    return window;
}

- (OIInspectorHeaderView *)headingButton;
{
    return headingButton;
}

- (BOOL)isExpanded;
{
    return isExpanded;
}

- (void)setExpanded:(BOOL)newState withNewTopLeftPoint:(NSPoint)topLeftPoint;
{
    switch (self.interfaceType) {
        case OIInspectorInterfaceTypeFloating:
            [self _setFloatingExpandedness:newState updateInspector:YES withNewTopLeftPoint:topLeftPoint animate:NO];
            break;
        case OIInspectorInterfaceTypeEmbedded:
            [self _setEmbeddedExpandedness:newState updateInspector:YES];
            break;
        // No default so the compiler warns if we add an item to the enum definition and don't handle it here
    }
}

- (NSString *)identifier;
{
    return [inspector identifier];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item;
{
    if ([item action] == @selector(toggleVisibleAction:)) {
        [item setState:isExpanded && [group isVisible]];
    }
    return YES;
}

- (CGFloat)headingHeight;
{
    return NSHeight([headingButton frame]);
}

- (CGFloat)desiredHeightWhenExpanded;
{
    OBPRECONDITION(headingButton); // That is, -loadInterface must have been called.
    CGFloat headingButtonHeight = headingButton ? NSHeight([headingButton frame]) : 0.0f;
    return NSHeight([[self _inspectorView] frame]) + headingButtonHeight;
}

- (void)toggleDisplay;
{
    if ([group isVisible]) {
        [self loadInterface]; // Load the UI and thus 'headingButton'
        [self headerViewDidToggleExpandedness:headingButton];
    } else {
        if (!isExpanded) {
            [self loadInterface]; // Load the UI and thus 'headingButton'
            [self headerViewDidToggleExpandedness:headingButton];
        }
        [group showGroup];
    }
}

- (void)updateTitle
{
    id newTitle;
    if ([inspector respondsToSelector:@selector(windowTitle)])
        newTitle = [(id)inspector windowTitle];
    else
        newTitle = [inspector displayName];
    [(id)headingButton setTitle:newTitle];
}

- (void)showInspector;
{
    if (![group isVisible] || !isExpanded)
        [self toggleDisplay];
    else
        [group orderFrontGroup]; 
}

- (BOOL)isVisible;
{
    return [group isVisible];
}

- (void)setBottommostInGroup:(BOOL)isBottom;
{
    if (isBottom == isBottommostInGroup)
        return;
    
    isBottommostInGroup = isBottom;
    if (window && !isExpanded) {
        NSRect windowFrame = [window frame];
        NSRect headingFrame;
        
        headingFrame.origin = NSMakePoint(0, isBottommostInGroup ? 0.0f : OIInspectorSpaceBetweenButtons);
        headingFrame.size = [headingButton frame].size;
        [window setFrame:NSMakeRect(NSMinX(windowFrame), NSMaxY(windowFrame) - NSMaxY(headingFrame), NSWidth(headingFrame), NSMaxY(headingFrame)) display:YES animate:NO];
    }
}

- (void)toggleExpandednessWithNewTopLeftPoint:(NSPoint)topLeftPoint animate:(BOOL)animate;
{
    switch (self.interfaceType) {
        case OIInspectorInterfaceTypeFloating:
            [self _setFloatingExpandedness:!isExpanded updateInspector:YES withNewTopLeftPoint:topLeftPoint animate:animate];
            break;
        case OIInspectorInterfaceTypeEmbedded:
            [self _setEmbeddedExpandedness:!isExpanded updateInspector:YES];
            break;
    }
}

- (void)updateExpandedness:(BOOL)allowAnimation; // call when the inspector sets its size internally by itself
{
    switch (self.interfaceType) {
        case OIInspectorInterfaceTypeFloating:
        {
            NSRect windowFrame = [window frame];
            [self _setFloatingExpandedness:isExpanded
                           updateInspector:NO
                       withNewTopLeftPoint:NSMakePoint(NSMinX(windowFrame), NSMaxY(windowFrame))
                                   animate:(allowAnimation && animateInspectorToggles)];
        }
            break;
        case OIInspectorInterfaceTypeEmbedded:
            [self _setEmbeddedExpandedness:isExpanded updateInspector:NO];
            break;
    }
    
    if (isExpanded && resizerView != nil)
        [self queueSelectorOnce:@selector(_saveInspectorHeight)];
}

- (void)setNewPosition:(NSPoint)aPosition;
{
    newPosition = aPosition;
}

- (void)setCollapseOnTakeNewPosition:(BOOL)yn;
{
    collapseOnTakeNewPosition = yn;
}

- (CGFloat)heightAfterTakeNewPosition;  // Returns the frame height (not the content view height)
{
    if (collapseOnTakeNewPosition) {
        NSRect eventualContentRect = (NSRect){ { 0, 0 }, { OIInspectorStartingHeaderButtonWidth, OIInspectorStartingHeaderButtonHeight } };
        if (isBottommostInGroup)
            eventualContentRect.size.height += OIInspectorSpaceBetweenButtons;
        return [window frameRectForContentRect:eventualContentRect].size.height;
    } else
        return NSHeight([window frame]);
}

- (void)takeNewPositionWithWidth:(CGFloat)aWidth;  // aWidth is the frame width (not the content width)
{
    if (collapseOnTakeNewPosition) {
        [self toggleExpandednessWithNewTopLeftPoint:newPosition animate:NO];
    } else {
        NSRect frame = [window frame];
        
        frame.origin.x = newPosition.x;
        frame.origin.y = newPosition.y - frame.size.height;
        frame.size.width = aWidth;
        [window setFrame:frame display:YES];
    }
    collapseOnTakeNewPosition = NO;
}

- (void)loadInterface;
{
    if ([[[self containerView] subviews] count] == 0) {
        [self _populateContainerView];
    }
    
    needsToggleBeforeDisplay = ([[[OIInspectorRegistry sharedInspector] workspaceDefaults] objectForKey:[self identifier]] != nil) != isExpanded;
}

- (void)prepareWindowForDisplay;
{
    OBPRECONDITION(window != nil);  // -loadInterface should have been called by this point.
    OBPRECONDITION(self.interfaceType == OIInspectorInterfaceTypeFloating);
    
    if (needsToggleBeforeDisplay && window) {
        
        needsToggleBeforeDisplay = NO;
        
        /* Need to reset this flag first, because expanding might cause our inspector to load its interface and lay itself out, thus informing us of the resize and reentering this method.
         
         Stack trace (r170537):
         
         #186	0x0000000100738437 in -[OIInspectorController prepareWindowForDisplay] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorController.m:271
         #187	0x000000010075a6b0 in -[OITabbedInspector _layoutSelectedTabs] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OITabbedInspector.m:721
         #188	0x0000000100754fb9 in -[OITabbedInspector awakeFromNib] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OITabbedInspector.m:109
         #189	0x00007fff8ba07a41 in -[NSIBObjectData nibInstantiateWithOwner:topLevelObjects:] ()
         #190	0x00007fff8b9fdf73 in loadNib ()
         #191	0x00007fff8b9fd676 in +[NSBundle(NSNibLoading) _loadNibFile:nameTable:withZone:ownerBundle:] ()
         #192	0x00007fff8bb9e580 in -[NSBundle(NSNibLoading) loadNibFile:externalNameTable:withZone:] ()
         #193	0x00000001001a06ac in -[NSBundle(OAExtensions) loadNibNamed:owner:] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniAppKit/OpenStepExtensions.subproj/NSBundle-OAExtensions.m:46
         #194	0x000000010075821a in -[OITabbedInspector inspectorView] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OITabbedInspector.m:477
         #195	0x0000000100739939 in -[OIInspectorController _inspectorView] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorController.m:445
         #196	0x0000000100739e4a in -[OIInspectorController _setExpandedness:updateInspector:withNewTopLeftPoint:animate:] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorController.m:479
         #197	0x0000000100737bb0 in -[OIInspectorController toggleExpandednessWithNewTopLeftPoint:animate:] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorController.m:211
         #198	0x0000000100738437 in -[OIInspectorController prepareWindowForDisplay] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorController.m:271
         #199	0x0000000100743bd7 in -[OIInspectorGroup _showGroup] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorGroup.m:799
         #200	0x000000010073f39e in -[OIInspectorGroup showGroup] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorGroup.m:356
         #201	0x00007fff88734fb1 in -[NSObject performSelector:] ()
         #202	0x00007fff887392dc in -[NSArray makeObjectsPerformSelector:] ()
         #203	0x000000010074bf36 in +[OIInspectorRegistry tabShowHidePanels] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OIInspectorRegistry.m:182
         #204	0x000000010075424a in -[OAApplication(OIExtensions) toggleInspectorPanel:] at /Volumes/SSD/OmniSource/MacTrunk/OmniGroup/Frameworks/OmniInspector/OAApplication-OIExtensions.m:25
        */
        
        NSRect windowFrame = [window frame];
        [self toggleExpandednessWithNewTopLeftPoint:NSMakePoint(NSMinX(windowFrame), NSMaxY(windowFrame)) animate:NO];
    }
    [self updateInspector];
}

- (void)displayWindow;
{
    OBPRECONDITION(self.interfaceType == OIInspectorInterfaceTypeFloating);
    [window orderFront:self];
    [window resetCursorRects];
}

- (void)updateInspector;
{
    // See -[NSWindow(OAExtensions) replacement_setFrame:display:animate:], basically recursive animation calls on the same window can lead to crashes.  Using a non-zero delay here since I'm not sure what mode the AppKit timer is in (and it could be changed later).  So, if it happens to be in NSDefaultRunLoopMode (unlikely, but still possible), we'll only end up being called and delaying 20x/sec.
    if ([[window contentView] inLiveResize]) {
        [self performSelector:_cmd withObject:nil afterDelay:0.05 inModes:[NSArray arrayWithObjects:NSDefaultRunLoopMode, nil]];
        return;
    }

    if (self.interfaceType == OIInspectorInterfaceTypeFloating && ![group isVisible])
        return;
    
    if (!isExpanded)
        return;

    NSArray *list = nil;
    NSResponder *oldResponder = nil;
    NS_DURING {
        
        // Don't update the inspector if the list of objects to inspect hasn't changed. -inspectedObjectsOfClass: returns a pointer-sorted list of objects, so we can just to 'identical' on the array.
        list = [self.nonretained_inspectorRegistry copyObjectsInterestingToInspector:inspector];
        if ((!list && !currentlyInspectedObjects) || [list isIdenticalToArray:currentlyInspectedObjects]) {
            [list release];
            NS_VOIDRETURN;
        }
        
        // Record what was first responder in the inspector before we clear it.  We want to clear it since resigning first responder can cause controls to send actions and thus we want this happen *before* we change what would be affected by the action!
        oldResponder = [[[window firstResponder] retain] autorelease];
        
        // See if we're dealing with the field editor - if so, we really want to deal with the view it's handling editing for instead.
        if ([oldResponder isKindOfClass:[NSText class]]) {
            id responderDelegate = [(NSText *)oldResponder delegate];
            if ([responderDelegate isKindOfClass:[NSSearchField class]]) {
                oldResponder = nil;  // (Bug #32481)  don't make the window the first responder if user is typing in a search field because it ends editing
                
            } else if ([responderDelegate isKindOfClass:[NSView class]]) {
                OBASSERT([(NSView *)responderDelegate window] == window);  // We'd never have a first responder who is an NSText who has an NSView as their delegate, where this isn't a field editor situation, right?
                oldResponder = (NSResponder *)responderDelegate;
            }
        }
        
        // A nil oldResponder means "don't end editing"
        if (oldResponder != nil) {
            [window makeFirstResponder:window];
            
            // Since this is delayed, there is really no reasonable way for a NSResponder to refuse to resign here.  The selection has *already* changed!
            OBASSERT([window firstResponder] == window);
        }
        
        [currentlyInspectedObjects release];
        currentlyInspectedObjects = list; // takes ownership of the reference
        list = nil;
        [inspector inspectObjects:currentlyInspectedObjects];
    } NS_HANDLER {
        NSLog(@"-[%@ %@]: *** %@", [self class], NSStringFromSelector(_cmd), localException);
        [self inspectNothing];
    } NS_ENDHANDLER;

    // Restore the old first responder, unless it was a view that is no longer in the view hierarchy
    if ([oldResponder isKindOfClass:[NSView class]]) {
        NSView *view = (NSView *)oldResponder;
        if ([view window] != window)
            oldResponder = nil;
    }
    if (oldResponder)
        [window makeFirstResponder:oldResponder];
    [list release];
}

- (void)inspectNothing;
{
    @try {
	[currentlyInspectedObjects release];
	currentlyInspectedObjects = nil;
        [inspector inspectObjects:nil];
    } @catch (NSException *exc) {
        OB_UNUSED_VALUE(exc);
    }
}

- (void)inspectorDidResize:(OIInspector *)resizedInspector;
{
    if (inspector != resizedInspector) {
        [inspector inspectorDidResize:resizedInspector];
    }
}

- (NSMutableDictionary *)debugDictionary;
{
    NSMutableDictionary *result = [super debugDictionary];
    
    
    [result setObject:[self identifier] forKey:@"identifier"];
    [result setObject:([window isVisible] ? @"YES" : @"NO") forKey:@"isVisible"];
    [result setObject:[window description] forKey:@"window"];
    if ([window childWindows])
        [result setObject:[[window childWindows] description] forKey:@"childWindows"];
    if ([window parentWindow])
        [result setObject:[[window parentWindow] description] forKey:@"parentWindow"];
    return result;
}

#pragma mark - Internal

- (IBAction)toggleVisibleAction:(id)sender;
{
    BOOL didExpand = NO;
    if (!isExpanded) {
        [self toggleDisplay];
        didExpand = YES;
    }
    if (![group isVisible]) {
        [group showGroup];
    } else if ([group isBelowOverlappingGroup]) {
        [group orderFrontGroup];
    } else if (!didExpand) {
        if ([group isOnlyExpandedMemberOfGroup:self])
            [group hideGroup];
        if ([[group inspectors] count] > 1) {
            [self loadInterface]; // Load the UI and thus 'headingButton'
            [self headerViewDidToggleExpandedness:headingButton];
        }
    }
}

#pragma mark - Private

- (void)_buildHeadingView;
{
    OBPRECONDITION(headingButton == nil);
    
    headingButton = [[OIInspectorHeaderView alloc] initWithFrame:NSMakeRect(0.0f, OIInspectorSpaceBetweenButtons,
                                                                            [[OIInspectorRegistry sharedInspector] inspectorWidth],
                                                                            OIInspectorStartingHeaderButtonHeight)];
    [headingButton setTitle:[inspector displayName]];

    NSImage *image = [inspector image];
    if (image)
	[headingButton setImage:image];

    NSString *keyEquivalent = [inspector shortcutKey];
    if ([keyEquivalent length]) {
        NSUInteger mask = [inspector shortcutModifierFlags];
        NSString *fullString = [NSString stringForKeyEquivalent:keyEquivalent andModifierMask:mask];
        [headingButton setKeyEquivalent:fullString];
    }
    [headingButton setDelegate:self];
    [headingButton setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
}

- (void)_buildWindow;
{
    window = [[OIInspectorWindow alloc] initWithContentRect:NSMakeRect(500.0f, 300.0f, NSWidth([headingButton frame]), OIInspectorStartingHeaderButtonHeight + OIInspectorSpaceBetweenButtons) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setDelegate:self];
    [window setBecomesKeyOnlyIfNeeded:YES];
}

- (void)_populateContainerView;
{
    [self _buildHeadingView];
    
    [[self containerView] addSubview:headingButton];
    
    headingBackground = [[OIInspectorHeaderBackground alloc] initWithFrame:[headingButton frame]];
    [headingBackground setAutoresizingMask:[headingButton autoresizingMask]];
    [headingBackground setHeaderView:headingButton];
    [[self containerView] addSubview:headingBackground positioned:NSWindowBelow relativeTo:nil];
}

- (NSView *)containerView;
{
    if (self.interfaceType == OIInspectorInterfaceTypeFloating) {
        if (window == nil) {
            [self _buildWindow];
        }
        
        return [window contentView];
    } else if (self.interfaceType == OIInspectorInterfaceTypeEmbedded) {
        if (self.embeddedContainerView == nil) {
            self.embeddedContainerView = [[[NSView alloc] init] autorelease];
        }
        
        return self.embeddedContainerView;
    } else {
        return nil;
    }
}

- (NSView *)_inspectorView;
{
    NSView *inspectorView = [inspector inspectorView];
    
    if (!loadedInspectorView) {
        forceResizeWidget = [inspector respondsToSelector:@selector(inspectorWillResizeToHeight:)]; 
        heightSizable = [inspectorView autoresizingMask] & NSViewHeightSizable ? YES : NO;

        if (forceResizeWidget) {
            _minimumHeight = 0;
        } else if ([inspector respondsToSelector:@selector(inspectorMinimumHeight)]) { 
            _minimumHeight = [inspector inspectorMinimumHeight];
        } else {
            _minimumHeight = [inspectorView frame].size.height;
        }
        
        NSString *savedHeightString = [[[OIInspectorRegistry sharedInspector] workspaceDefaults] objectForKey:[NSString stringWithFormat:@"%@-Height", [self identifier]]];

	NSSize size = [inspectorView frame].size;
	OBASSERT(size.width <= [[OIInspectorRegistry sharedInspector] inspectorWidth]); // OK to make inspectors wider, but probably indicates a problem if the nib is wider than the global inspector width
        if (size.width > [[OIInspectorRegistry sharedInspector] inspectorWidth]) {
            NSLog(@"Inspector %@ is wider (%g) than grouped width (%g)", [self identifier], size.width, [[OIInspectorRegistry sharedInspector] inspectorWidth]);
        }
	size.width = [[OIInspectorRegistry sharedInspector] inspectorWidth];
	
        if (savedHeightString != nil && heightSizable)
	    size.height = [savedHeightString floatValue];
	[inspectorView setFrameSize:size];
	
        loadedInspectorView = YES;
    }
    return inspectorView;
}

- (void)_setFloatingExpandedness:(BOOL)expanded updateInspector:(BOOL)updateInspector withNewTopLeftPoint:(NSPoint)topLeftPoint animate:(BOOL)animate;
{
    OBPRECONDITION(self.interfaceType == OIInspectorInterfaceTypeFloating);
    NSView *view = [self _inspectorView];
    BOOL hadVisibleInspectors = [[OIInspectorRegistry sharedInspector] hasVisibleInspector];

    if (!animateInspectorToggles)
        animate = NO;

    isExpanded = expanded;
    isSettingExpansion = YES;
    [group setScreenChangesEnabled:NO];
    [headingButton setExpanded:isExpanded];

    CGFloat additionalHeaderHeight;
    
    if (isExpanded) {

        if (updateInspector) {
            // If no inspectors were previously visible, the inspector registry's selection set may not be up-to-date, so tell it to update
            // (an alternate approach would be to have the registry keep track of whether or not it was up to date, and here we would simply tell the registry to update if it needed to, rather than us basing this off of whether or not any inspectors were previously visible, thus requiring us to know that -[OIInspectorRegistry _recalculateInspectorsAndInspectWindow] doesn't do anything if no inspectors are visible)
            if (!hadVisibleInspectors)
                [OIInspectorRegistry updateInspector];
            [self updateInspector]; // call this first because the view could change sizes based on the selection in -updateInspector
        }
            
        NSRect viewFrame = [view frame];
        NSRect newContentRect = NSMakeRect(0, 0,
                                           NSWidth(viewFrame),
                                           NSHeight([headingButton frame]) + NSHeight(viewFrame));
        NSRect windowFrame = [window frameRectForContentRect:newContentRect];
        windowFrame.origin.x = topLeftPoint.x;
        windowFrame.origin.y = topLeftPoint.y - windowFrame.size.height;
        windowFrame = [self windowWillResizeFromFrame:[window frame] toFrame:windowFrame];

        if (forceResizeWidget) {
            viewFrame = NSMakeRect(0, 0, NSWidth(newContentRect), NSHeight(viewFrame));
        } else {
            viewFrame.origin.x = (CGFloat)floor((NSWidth(newContentRect) - NSWidth(viewFrame)) / 2.0);
            viewFrame.origin.y = 0;
        }

        additionalHeaderHeight = [inspector additionalHeaderHeight];
        
        [view setFrame:viewFrame];
        [view setAutoresizingMask:NSViewNotSizable];
        [[self containerView] addSubview:view positioned:NSWindowBelow relativeTo:headingButton];
        [window setFrame:windowFrame display:YES animate:animate];
        if (forceResizeWidget || heightSizable) {
            if (!resizerView) {
                resizerView = [[OIInspectorResizer alloc] initWithFrame:NSMakeRect(0, 0, OIInspectorResizerWidth, OIInspectorResizerWidth)];
                [resizerView setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
            }
            [resizerView setFrameOrigin:NSMakePoint(NSMaxX(newContentRect) - OIInspectorResizerWidth, 0)];
            [[self containerView] addSubview:resizerView];
        }
        [view setAutoresizingMask:NSViewHeightSizable | NSViewMinXMargin | NSViewMaxXMargin];
        [[[OIInspectorRegistry sharedInspector] workspaceDefaults] setObject:@"YES" forKey:[self identifier]];
    } else {
	[window makeFirstResponder:window];

        [resizerView removeFromSuperview];
        [view setAutoresizingMask:NSViewNotSizable];
	
        NSRect headingFrame;
        headingFrame.origin = NSMakePoint(0, isBottommostInGroup ? 0.0f : OIInspectorSpaceBetweenButtons);
        if (group == nil)
            headingFrame.size = [headingButton frame].size;
        else
            headingFrame.size = NSMakeSize([[OIInspectorRegistry sharedInspector] inspectorWidth], [headingButton frame].size.height);
        NSRect headingWindowFrame = [window frameRectForContentRect:headingFrame];
        headingWindowFrame.origin.x = topLeftPoint.x;
        headingWindowFrame.origin.y = topLeftPoint.y - headingWindowFrame.size.height;
        [window setFrame:headingWindowFrame display:YES animate:animate];
        [view removeFromSuperview];

        additionalHeaderHeight = 0;
        
        if (updateInspector)
            [self inspectNothing];
        
        [[[OIInspectorRegistry sharedInspector] workspaceDefaults] removeObjectForKey:[self identifier]];
    }
    
    NSRect headingFrame;
    if (additionalHeaderHeight > 0) {
        headingFrame = [headingButton frame];
        headingFrame.size.height += additionalHeaderHeight;
        headingFrame.origin.y -= additionalHeaderHeight;
    } else
        headingFrame = [headingButton frame];
    if (!NSEqualRects(headingFrame, [headingBackground frame])) {
        [headingBackground setFrame:headingFrame];
        [headingBackground setNeedsDisplay:YES];
    }
    
    [[OIInspectorRegistry sharedInspector] configurationsChanged];
    
    [group setScreenChangesEnabled:YES];
    isSettingExpansion = NO;
    
    [self _postExpandednessChangedNotification];
}

- (void)_setEmbeddedExpandedness:(BOOL)expanded updateInspector:(BOOL)updateInspector;
{
    OBFinishPortingLater("Add back animated argument?");
    OBPRECONDITION(self.interfaceType == OIInspectorInterfaceTypeEmbedded);
    
    if (expanded == isExpanded)
        return;
    BOOL hadVisibleInspector = [self.nonretained_inspectorRegistry hasVisibleInspector];
    isExpanded = expanded;
    
    if (updateInspector) {
        if (!hadVisibleInspector) {
            [self.nonretained_inspectorRegistry updateInspectionSetImmediatelyAndUnconditionallyForWindow:[[self containerView] window]];
        }
        [self updateInspector];
    }
    
    NSView *inspectorView = [self _inspectorView];
    if (expanded) {
        // Ensure the container view has some sort of reasonable frame (so the autoresizing masks work). It'll get re-laid-out later.
        if (NSEqualRects(NSZeroRect, [[self containerView] frame])) {
            [[self containerView] setFrame:NSMakeRect(0, 0, 200, 200)];
        }
        
        [[self containerView] addSubview:inspectorView];
        NSRect containerBounds = [[self containerView] bounds];
        CGFloat headerHeight = NSHeight(headingBackground.frame);
        inspectorView.frame = (NSRect){
            .origin = (NSPoint){
                .x = 0,
                .y = [[self containerView] isFlipped] ? headerHeight : 0
            },
            .size = (NSSize){
                .width = NSWidth(containerBounds),
                .height = MAX(NSHeight(containerBounds) - headerHeight, 0)
            }
        };
        inspectorView.autoresizingMask = (NSViewWidthSizable | NSViewHeightSizable);
    } else {
        [inspectorView removeFromSuperview];
    }
    
    for (NSView *view in @[ headingButton, headingBackground] ){
        NSRect frame = view.frame;
        frame.origin.y = NSMaxY([[self containerView] bounds]) - [self headingHeight];
        view.frame = frame;
    }
    
    [self _postExpandednessChangedNotification];
}

- (void)_postExpandednessChangedNotification;
{
    NSDictionary *userInfo = @{ @"isExpanded" : @(isExpanded) };
    NSNotification *notification = [[[NSNotification alloc] initWithName:OIInspectorControllerDidChangeExpandednessNotification
                                                                  object:self
                                                                userInfo:userInfo] autorelease];
    [[NSNotificationCenter defaultCenter] postNotification:notification];
}

- (void)_saveInspectorHeight;
{
    OIInspectorRegistry *registry = [OIInspectorRegistry sharedInspector];
    NSSize size = [[self _inspectorView] frame].size;

    [[registry workspaceDefaults] setObject:[NSNumber numberWithCGFloat:size.height] forKey:[NSString stringWithFormat:@"%@-Height", [self identifier]]];
    [registry defaultsDidChange];
}

- (BOOL)_groupCanBeginResizingOperation;
{
    if (group) {
        return [group canBeginResizingOperation];
    } else {
        return (self.interfaceType == OIInspectorInterfaceTypeEmbedded);
    }
}

#pragma mark NSWindow delegate

- (void)windowDidMove:(NSNotification *)notification;
{
    OIInspectorRegistry *registry = [OIInspectorRegistry sharedInspector];
    [registry configurationsChanged]; 
}

- (void)windowWillClose:(NSNotification *)notification;
{
    [self inspectNothing];
}

- (void)windowDidBecomeKey:(NSNotification *)notification;
{
    [headingBackground setNeedsDisplay:YES];
}

- (void)windowDidResignKey:(NSNotification *)notification;
{
    [headingBackground setNeedsDisplay:YES];
    [window makeFirstResponder:window];
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)aWindow;
{
    NSWindow *mainWindow;
    NSResponder *nextResponder;
    NSUndoManager *undoManager = nil;
    
    mainWindow = [NSApp mainWindow];
    nextResponder = [mainWindow firstResponder];
    if (nextResponder == nil)
        nextResponder = mainWindow;
    
    do {
        if ([nextResponder respondsToSelector:@selector(undoManager)])
            undoManager = [nextResponder undoManager];
        else if ([nextResponder respondsToSelector:@selector(delegate)] && [[(id)nextResponder delegate] respondsToSelector:@selector(undoManager)])
            undoManager = [[(id)nextResponder delegate] undoManager];
        nextResponder = [nextResponder nextResponder];
    } while (nextResponder && !undoManager);
    
    return undoManager;
}

#pragma mark OIInspectorWindow delegate

- (void)windowWillBeginResizing:(NSWindow *)resizingWindow;
{
    OBASSERT(resizingWindow == window);
    [group inspectorWillStartResizing:self];
}

- (void)windowDidFinishResizing:(NSWindow *)resizingWindow;
{
    OBASSERT(resizingWindow == window);
    [group inspectorDidFinishResizing:self];
}

/*"
 If you call this method, you must also call -windowDidFinishResizing: after the resize is actually complete. The reason is that this method calls a corresponding method on the inspector group which sets up some resizing stuff that must be cleaned up when the resizing is complete.
 Good news, everybody! OIInspectorWindow automatically calls -windowDidFinishResizing: at the end of -setFrame:display:animate:, so if that's the method you use to perform the actual resize, you don't need to call -windowDidFinishResizing: yourself.
"*/
- (NSRect)windowWillResizeFromFrame:(NSRect)fromRect toFrame:(NSRect)toRect;
{
    NSRect result;

    if ([group ignoreResizing]) {
        return toRect;
    }

    NSRect newContentRect = [window contentRectForFrameRect:toRect];
    
    if (isExpanded && !isSettingExpansion) {
        if ([inspector respondsToSelector:@selector(inspectorMinimumHeight)])
            _minimumHeight = [inspector inspectorMinimumHeight];

        if (NSHeight(newContentRect) < _minimumHeight)
            newContentRect.size.height = _minimumHeight;
    }
    if (isExpanded && forceResizeWidget) {
        newContentRect.size.height -= OIInspectorStartingHeaderButtonHeight;
        newContentRect.size.height = [inspector inspectorWillResizeToHeight:newContentRect.size.height];
        newContentRect.size.height += OIInspectorStartingHeaderButtonHeight;
    }

    newContentRect.size.width = [[OIInspectorRegistry sharedInspector] inspectorWidth];
    
    toRect = [window frameRectForContentRect:newContentRect];
    
    if (isExpanded && !isSettingExpansion && !forceResizeWidget && !heightSizable) {
        toRect.origin.y += NSHeight(fromRect) - NSHeight(toRect);
        toRect.size.height = NSHeight(fromRect);
    }
    
    if (group != nil) {
        result = [group inspector:self willResizeToFrame:toRect isSettingExpansion:isSettingExpansion];
	OBASSERT(result.size.width == toRect.size.width); // Not allowed to width-size inspectors ever!
    } else
        result = toRect;
    
    if (isExpanded && !isSettingExpansion && resizerView != nil)
        [self queueSelectorOnce:@selector(_saveInspectorHeight)];
    return result;
}

#pragma mark OIInspectorHeaderViewDelegateProtocol

- (BOOL)headerViewShouldDisplayCloseButton:(OIInspectorHeaderView *)view;
{
    return [group isHeadOfGroup:self];
}

- (BOOL)headerViewShouldAllowDragging:(OIInspectorHeaderView *)view;
{
    return (self.interfaceType == OIInspectorInterfaceTypeFloating);
}

- (CGFloat)headerViewDraggingHeight:(OIInspectorHeaderView *)view;
{
    NSRect myGroupFrame;
    
    if (!window || ![group getGroupFrame:&myGroupFrame]) {
        OBASSERT_NOT_REACHED("Can't calculate headerViewDraggingHeight");
        return 1.0f;
    }
    
    return NSMaxY([window frame]) - myGroupFrame.origin.y;
}

- (void)headerViewDidBeginDragging:(OIInspectorHeaderView *)view;
{
    OBPRECONDITION([self headerViewShouldAllowDragging:view]);
    [group detachFromGroup:self];
}

- (NSRect)headerView:(OIInspectorHeaderView *)view willDragWindowToFrame:(NSRect)aFrame onScreen:(NSScreen *)screen;
{
    aFrame = [group fitFrame:aFrame onScreen:screen forceVisible:NO];
    aFrame = [group snapToOtherGroupWithFrame:aFrame];
    return aFrame;
}

- (void)headerViewDidEndDragging:(OIInspectorHeaderView *)view toFrame:(NSRect)aFrame;
{
    OBPRECONDITION([self headerViewShouldAllowDragging:view]);
    [group windowsDidMoveToFrame:aFrame];
}

- (void)headerViewDidToggleExpandedness:(OIInspectorHeaderView *)senderButton;
{
    OBPRECONDITION(senderButton);
    
    if ([self _groupCanBeginResizingOperation]) {
        NSRect windowFrame = [window frame];
        [self toggleExpandednessWithNewTopLeftPoint:NSMakePoint(NSMinX(windowFrame), NSMaxY(windowFrame)) animate:YES];
    } else {
        // try again when the current resizing operation may be done
        [self performSelector:@selector(headerViewDidToggleExpandedness:) withObject:senderButton afterDelay:0.1];
    }
}

- (void)headerViewDidClose:(OIInspectorHeaderView *)view;
{
    [group hideGroup];
}

@end
