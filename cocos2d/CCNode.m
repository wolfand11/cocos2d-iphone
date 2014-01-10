/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2009 Valentin Milea
 *
 * Copyright (c) 2008-2010 Ricardo Quesada
 * Copyright (c) 2011 Zynga Inc.
 * Copyright (c) 2013 Lars Birkemose
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#import "CCNode.h"
#import "CCNode_Private.h"
#import "CCDirector.h"
#import "CCActionManager.h"
#import "CCScheduler.h"
#import "ccConfig.h"
#import "ccMacros.h"
#import "Support/CGPointExtension.h"
#import "Support/TransformUtils.h"
#import "ccMacros.h"
#import "CCGLProgram.h"
#import "CCPhysics+ObjectiveChipmunk.h"
#import "CCDirector_Private.h"

// externals
#import "kazmath/GL/matrix.h"

#ifdef __CC_PLATFORM_IOS
#import "Platforms/iOS/CCDirectorIOS.h"
#endif


#if CC_NODE_RENDER_SUBPIXEL
#define RENDER_IN_SUBPIXEL
#else
#define RENDER_IN_SUBPIXEL(__ARGS__) (ceil(__ARGS__))
#endif


#pragma mark - Node

@interface CCNode ()
// lazy allocs
-(void) childrenAlloc;
// helper that reorder a child
-(void) insertChild:(CCNode*)child z:(NSInteger)z;
// used internally to alter the zOrder variable. DON'T call this method manually
-(void) _setZOrder:(NSInteger) z;
-(void) detachChild:(CCNode *)child cleanup:(BOOL)doCleanup;
@end

@implementation CCNode {

}

// Suppress automatic ivar creation.
@dynamic runningInActiveScene;
@dynamic paused;

static inline
CCPhysicsBody *
GetBodyIfRunning(CCNode *node)
{
	return (node->_isInActiveScene ? node->_physicsBody : nil);
}

static inline CGAffineTransform
NodeToPhysicsTransform(CCNode *node)
{
	CGAffineTransform transform = CGAffineTransformIdentity;
	for(CCNode *n = node; n && !n.isPhysicsNode; n = n.parent){
		transform = cpTransformMult(n.nodeToParentTransform, transform);
	}
	
	return transform;
}

static inline float
NodeToPhysicsRotation(CCNode *node)
{
	float rotation = 0.0;
	for(CCNode *n = node; n && !n.isPhysicsNode; n = n.parent){
		rotation -= n.rotationalSkewX;
	}
	
	return rotation;
}

static inline CGAffineTransform
RigidBodyToParentTransform(CCNode *node, CCPhysicsBody *body)
{
	return cpTransformMult(cpTransformInverse(NodeToPhysicsTransform(node.parent)), body.absoluteTransform);
}

// XXX: Yes, nodes might have a sort problem once every 15 days if the game runs at 60 FPS and each frame sprites are reordered.
static NSUInteger globalOrderOfArrival = 1;

@synthesize children = _children;
@synthesize visible = _visible;
@synthesize parent = _parent;
@synthesize zOrder = _zOrder;
@synthesize name = _name;
@synthesize vertexZ = _vertexZ;
@synthesize userObject = _userObject;
@synthesize	shaderProgram = _shaderProgram;
@synthesize orderOfArrival = _orderOfArrival;
@synthesize glServerState = _glServerState;
@synthesize physicsBody = _physicsBody;

#pragma mark CCNode - Transform related properties

@synthesize scaleX = _scaleX, scaleY = _scaleY;
@synthesize anchorPoint = _anchorPoint, anchorPointInPoints = _anchorPointInPoints;
@synthesize contentSize = _contentSize;
@synthesize skewX = _skewX, skewY = _skewY;

#pragma mark CCNode - Init & cleanup

+(id) node
{
	return [[self alloc] init];
}

-(id) init
{
	if ((self=[super init]) ) {
		_isInActiveScene = NO;

		_skewX = _skewY = 0.0f;
		_rotationalSkewX = _rotationalSkewY = 0.0f;
		_scaleX = _scaleY = 1.0f;
        _position = CGPointZero;
        _contentSize = CGSizeZero;
		_anchorPointInPoints = _anchorPoint = CGPointZero;

		_isTransformDirty = _isInverseDirty = YES;

		_vertexZ = 0;

		_visible = YES;

		_zOrder = 0;

		// children (lazy allocs)
		_children = nil;

		// userObject is always inited as nil
		_userObject = nil;

		//initialize parent to nil
		_parent = nil;

		_shaderProgram = nil;

		_orderOfArrival = 0;

		_glServerState = 0;
		
		// set default scheduler and actionManager
		CCDirector *director = [CCDirector sharedDirector];
		_actionManager = [director actionManager];
		_scheduler = [director scheduler];
        
		// set default touch handling
		self.hitAreaExpansion = 0.0f;
    
		_displayColor = _color = [CCColor whiteColor].ccColor4f;
		_cascadeOpacityEnabled = NO;
		_cascadeColorEnabled = NO;
	}

	return self;
}

- (void)cleanup
{
	// actions
	[self stopAllActions];
	[_scheduler unscheduleTarget:self];

	// timers
	[_children makeObjectsPerformSelector:@selector(cleanup)];
}

- (NSString*) description
{
	return [NSString stringWithFormat:@"<%@ = %p | Name = %@>", [self class], self, _name];
}

- (void) dealloc
{
	CCLOGINFO( @"cocos2d: deallocing %@", self);


	// children
    for (CCNode* child in _children)
		child.parent = nil;


}

#pragma mark Setters

// getters synthesized, setters explicit
-(void) setRotation: (float)newRotation
{
	CCPhysicsBody *body = GetBodyIfRunning(self);
	if(body){
		body.absoluteRadians = -CC_DEGREES_TO_RADIANS(newRotation + NodeToPhysicsRotation(self.parent));
	} else {
		_rotationalSkewX = newRotation;
		_rotationalSkewY = newRotation;
		_isTransformDirty = _isInverseDirty = YES;
	}
}

-(float) rotation
{
	CCPhysicsBody *body = GetBodyIfRunning(self);
	if(body){
		return -CC_RADIANS_TO_DEGREES(body.absoluteRadians) + NodeToPhysicsRotation(self.parent);
	} else {
		NSAssert( _rotationalSkewX == _rotationalSkewY, @"CCNode#rotation. RotationX != RotationY. Don't know which one to return");
		return _rotationalSkewX;
	}
}

-(float)rotationalSkewX {
	return _rotationalSkewX;
}

-(void) setRotationalSkewX: (float)newX
{
	NSAssert(_physicsBody == nil, @"Currently physics nodes don't support skewing.");
	
	_rotationalSkewX = newX;
	_isTransformDirty = _isInverseDirty = YES;
}

-(float)rotationalSkewY
{
	return _rotationalSkewY;
}

-(void) setRotationalSkewY: (float)newY
{
	NSAssert(_physicsBody == nil, @"Currently physics nodes don't support skewing.");
	
	_rotationalSkewY = newY;
	_isTransformDirty = _isInverseDirty = YES;
}

-(void) setScaleX: (float)newScaleX
{
	_scaleX = newScaleX;
	_isTransformDirty = _isInverseDirty = YES;
}

-(void) setScaleY: (float)newScaleY
{
	_scaleY = newScaleY;
	_isTransformDirty = _isInverseDirty = YES;
}

-(void) setSkewX:(float)newSkewX
{
	NSAssert(_physicsBody == nil, @"Currently physics nodes don't support skewing.");
	
	_skewX = newSkewX;
	_isTransformDirty = _isInverseDirty = YES;
}

-(void) setSkewY:(float)newSkewY
{
	NSAssert(_physicsBody == nil, @"Currently physics nodes don't support skewing.");
	
	_skewY = newSkewY;
	_isTransformDirty = _isInverseDirty = YES;
}

static inline CGPoint
GetPositionFromBody(CCNode *node, CCPhysicsBody *body)
{
	return cpTransformPoint([node nodeToParentTransform], node->_anchorPointInPoints);
}

-(CGPoint)position
{
	CCPhysicsBody *body = GetBodyIfRunning(self);
	if(body){
		return [self convertPositionFromPoints:GetPositionFromBody(self, body) type:_positionType];
	} else {
		return _position;
	}
}

-(void) setPosition: (CGPoint)newPosition
{
	CCPhysicsBody *body = GetBodyIfRunning(self);
	if(body){
		CGPoint currentPosition = GetPositionFromBody(self, body);
		CGPoint delta = ccpSub([self convertPositionToPoints:newPosition type:_positionType], currentPosition);
		body.absolutePosition = ccpAdd(body.absolutePosition, cpTransformVect(NodeToPhysicsTransform(self.parent), delta));
	} else {
		_position = newPosition;
		_isTransformDirty = _isInverseDirty = YES;
	}
}

-(void)setPositionType:(CCPositionType)positionType
{
	_positionType = positionType;
	_isTransformDirty = _isInverseDirty = YES;
}

-(void) setAnchorPoint:(CGPoint)point
{
	if( ! CGPointEqualToPoint(point, _anchorPoint) ) {
		_anchorPoint = point;
        CGSize contentSizeInPoints = self.contentSizeInPoints;
		_anchorPointInPoints = ccp( contentSizeInPoints.width * _anchorPoint.x, contentSizeInPoints.height * _anchorPoint.y );
		_isTransformDirty = _isInverseDirty = YES;
	}
}

-(void) setContentSize:(CGSize)size
{
	if( ! CGSizeEqualToSize(size, _contentSize) )
    {
		_contentSize = size;
        [self contentSizeChanged];
	}
}

- (void) setContentSizeType:(CCSizeType)contentSizeType
{
    _contentSizeType = contentSizeType;
    [self contentSizeChanged];
}

- (void) contentSizeChanged
{
    // Update children
    CGSize contentSizeInPoints = self.contentSizeInPoints;
    _anchorPointInPoints = ccp( contentSizeInPoints.width * _anchorPoint.x, contentSizeInPoints.height * _anchorPoint.y );
    _isTransformDirty = _isInverseDirty = YES;
    
    if ([_parent isKindOfClass:[CCLayout class]])
    {
        CCLayout* layout = (CCLayout*)_parent;
        [layout needsLayout];
    }
    
    // Update the children (if needed)
    for (CCNode* child in _children)
    {
        if (!CCPositionTypeIsBasicPoints(child->_positionType))
        {
            // This is a position type affected by content size
            child->_isTransformDirty = _isInverseDirty = YES;
        }
    }
}

- (CGSize) convertContentSizeToPoints:(CGSize)contentSize type:(CCSizeType)type
{
    CGSize size = CGSizeZero;
    CCDirector* director = [CCDirector sharedDirector];
    
    CCSizeUnit widthUnit = type.widthUnit;
    CCSizeUnit heightUnit = type.heightUnit;
    
    // Width
    if (widthUnit == CCSizeUnitPoints)
    {
        size.width = contentSize.width;
    }
    else if (widthUnit == CCSizeUnitUIPoints)
    {
        size.width = director.UIScaleFactor * contentSize.width;
    }
    else if (widthUnit == CCSizeUnitNormalized)
    {
        size.width = contentSize.width * _parent.contentSizeInPoints.width;
    }
    else if (widthUnit == CCSizeUnitInsetPoints)
    {
        size.width = _parent.contentSizeInPoints.width - contentSize.width;
    }
    else if (widthUnit == CCSizeUnitInsetUIPoints)
    {
        size.width = _parent.contentSizeInPoints.width - contentSize.width * director.UIScaleFactor;
    }
    
    // Height
    if (heightUnit == CCSizeUnitPoints)
    {
        size.height = contentSize.height;
    }
    else if (heightUnit == CCSizeUnitUIPoints)
    {
        size.height = director.UIScaleFactor * contentSize.height;
    }
    else if (heightUnit == CCSizeUnitNormalized)
    {
        size.height = contentSize.height * _parent.contentSizeInPoints.height;
    }
    else if (heightUnit == CCSizeUnitInsetPoints)
    {
        size.height = _parent.contentSizeInPoints.height - contentSize.height;
    }
    else if (heightUnit == CCSizeUnitInsetUIPoints)
    {
        size.height = _parent.contentSizeInPoints.height - contentSize.height * director.UIScaleFactor;
    }
    
    return size;
}

- (CGSize) convertContentSizeFromPoints:(CGSize)pointSize type:(CCSizeType)type
{
    CGSize size = CGSizeZero;
    
    CCDirector* director = [CCDirector sharedDirector];
    
    CCSizeUnit widthUnit = type.widthUnit;
    CCSizeUnit heightUnit = type.heightUnit;
    
    // Width
    if (widthUnit == CCSizeUnitPoints)
    {
        size.width = pointSize.width;
    }
    else if (widthUnit == CCSizeUnitUIPoints)
    {
        size.width = pointSize.width / director.UIScaleFactor;
    }
    else if (widthUnit == CCSizeUnitNormalized)
    {
        
        float parentWidthInPoints = _parent.contentSizeInPoints.width;
        if (parentWidthInPoints > 0)
        {
            size.width = pointSize.width/parentWidthInPoints;
        }
        else
        {
            size.width = 0;
        }
    }
    else if (widthUnit == CCSizeUnitInsetPoints)
    {
        size.width = _parent.contentSizeInPoints.width - pointSize.width;
    }
    else if (widthUnit == CCSizeUnitInsetUIPoints)
    {
        size.width = (_parent.contentSizeInPoints.width - pointSize.width) / director.UIScaleFactor;
    }
    
    // Height
    if (heightUnit == CCSizeUnitPoints)
    {
        size.height = pointSize.height;
    }
    else if (heightUnit == CCSizeUnitUIPoints)
    {
        size.height = pointSize.height / director.UIScaleFactor;
    }
    else if (heightUnit == CCSizeUnitNormalized)
    {
        
        float parentHeightInPoints = _parent.contentSizeInPoints.height;
        if (parentHeightInPoints > 0)
        {
            size.height = pointSize.height/parentHeightInPoints;
        }
        else
        {
            size.height = 0;
        }
    }
    else if (heightUnit == CCSizeUnitInsetPoints)
    {
        size.height = _parent.contentSizeInPoints.height - pointSize.height;
    }
    else if (heightUnit == CCSizeUnitInsetUIPoints)
    {
        size.height = (_parent.contentSizeInPoints.height - pointSize.height) / director.UIScaleFactor;
    }
    
    return size;
}

- (CGSize) contentSizeInPoints
{
    return [self convertContentSizeToPoints:self.contentSize type:_contentSizeType];
}

- (float) scaleInPoints
{
    if (_scaleType == CCScaleTypeScaled)
    {
        return self.scale * [CCDirector sharedDirector].UIScaleFactor;
    }
    return self.scale;
}

- (float) scaleXInPoints
{
    if (_scaleType == CCScaleTypeScaled)
    {
        return _scaleX * [CCDirector sharedDirector].UIScaleFactor;
    }
    return _scaleX;
}

- (float) scaleYInPoints
{
    if (_scaleType == CCScaleTypeScaled)
    {
        return _scaleY * [CCDirector sharedDirector].UIScaleFactor;
    }
    return _scaleY;
}

- (void) setScaleType:(CCScaleType)scaleType
{
    _scaleType = scaleType;
    _isTransformDirty = _isInverseDirty = YES;
}

- (CGRect) boundingBox
{
    CGSize contentSize = self.contentSizeInPoints;
    CGRect rect = CGRectMake(0, 0, contentSize.width, contentSize.height);
    return CGRectApplyAffineTransform(rect, [self nodeToParentTransform]);
}

-(void) setVertexZ:(float)vertexZ
{
	_vertexZ = vertexZ;
}

- (void)setVisible:(BOOL)visible
{
    if (visible == _visible) return;
    
    [[[CCDirector sharedDirector] responderManager] markAsDirty];
    _visible = visible;
}

-(float) scale
{
	NSAssert( _scaleX == _scaleY, @"CCNode#scale. ScaleX != ScaleY. Don't know which one to return");
	return _scaleX;
}

-(void) setScale:(float) s
{
	_scaleX = _scaleY = s;
	_isTransformDirty = _isInverseDirty = YES;
}

- (void) setZOrder:(NSInteger)zOrder
{
	[self _setZOrder:zOrder];

    if (_parent)
        [_parent reorderChild:self z:zOrder];
}

#pragma mark CCNode Composition

-(void) childrenAlloc
{
	_children = [[NSMutableArray alloc] init];
}

-(CCNode*) getChildByName:(NSString *)name recursively:(bool)isRecursive
{
	NSAssert(name, @"name is NULL");
	if([self.name isEqualToString:name]){
		return self;
	}
	
  for (CCNode* node in _children) {
		if(isRecursive){
			// Recurse:
			CCNode* n = [node getChildByName:name recursively:isRecursive];
			if(n)
				return n;
		}else{
			if([node.name isEqualToString:name]){
				return node;
			}
		}
	}
	
	// not found
	return nil;
}

// Recursively increment/decrement _pausedAncestors on the children of 'node'.
static void
RecursivelyIncrementPausedAncestors(CCNode *node, int increment)
{
	NSArray *children = node->_children;
	for(NSUInteger i=0, count=children.count; i<count; i++){
		CCNode *child = children[i];
		
		BOOL wasRunning = node.runningInActiveScene;
		child->_pausedAncestors += increment;
		[node wasRunning:wasRunning];
		
		RecursivelyIncrementPausedAncestors(child, increment);
	}
}

/* "add" logic MUST only be on this method
 * If a class want's to extend the 'addChild' behaviour it only needs
 * to override this method
 */
-(void) addChild: (CCNode*)child z:(NSInteger)z name:(NSString*)name
{
	NSAssert( child != nil, @"Argument must be non-nil");
	NSAssert( child.parent == nil, @"child already added to another node. It can't be added again");

	if( ! _children )
		[self childrenAlloc];

	[self insertChild:child z:z];

	child.name = name;

	[child setParent: self];

	[child setOrderOfArrival: globalOrderOfArrival++];
	
	// Update pausing parameters
	child->_pausedAncestors = _pausedAncestors + (_paused ? 1 : 0);
	RecursivelyIncrementPausedAncestors(child, child->_pausedAncestors);
	
	if( _isInActiveScene ) {
		[child onEnter];
		[child onEnterTransitionDidFinish];
	}
    
    [[[CCDirector sharedDirector] responderManager] markAsDirty];
}

-(void) addChild: (CCNode*) child z:(NSInteger)z
{
	NSAssert( child != nil, @"Argument must be non-nil");
	[self addChild:child z:z name:child.name];
}

-(void) addChild: (CCNode*) child
{
	NSAssert( child != nil, @"Argument must be non-nil");
	[self addChild:child z:child.zOrder name:child.name];
}

-(void) removeFromParent
{
	[self removeFromParentAndCleanup:YES];
}

-(void) removeFromParentAndCleanup:(BOOL)cleanup
{
	[_parent removeChild:self cleanup:cleanup];
}

-(void) removeChild: (CCNode*)child
{
	[self removeChild:child cleanup:YES];
}

/* "remove" logic MUST only be on this method
 * If a class wants to extend the 'removeChild' behavior it only needs
 * to override this method
 */
-(void) removeChild: (CCNode*)child cleanup:(BOOL)cleanup
{
	// explicit nil handling
	if (child == nil)
		return;

	NSAssert([_children containsObject:child], @"This node does not contain the specified child.");
	
	[self detachChild:child cleanup:cleanup];
}

-(void) removeChildByName:(NSString*)name
{
	[self removeChildByName:name cleanup:YES];
}

-(void) removeChildByName:(NSString*)name cleanup:(BOOL)cleanup
{
	NSAssert( !name, @"Invalid name");

	CCNode *child = [self getChildByName:name recursively:NO];

	if (child == nil)
		CCLOG(@"cocos2d: removeChildByName: child not found!");
	else
		[self removeChild:child cleanup:cleanup];
}

-(void) removeAllChildren
{
	[self removeAllChildrenWithCleanup:YES];
}

-(void) removeAllChildrenWithCleanup:(BOOL)cleanup
{
	// not using detachChild improves speed here
    for (CCNode* c in _children)
	{
		// IMPORTANT:
		//  -1st do onExit
		//  -2nd cleanup
		if (_isInActiveScene)
		{
			[c onExitTransitionDidStart];
			[c onExit];
		}
		
		RecursivelyIncrementPausedAncestors(c, -c->_pausedAncestors);
		c->_pausedAncestors = 0;
		
		if (cleanup)
			[c cleanup];

		// set parent nil at the end (issue #476)
		[c setParent:nil];
        
        [[[CCDirector sharedDirector] responderManager] markAsDirty];

	}

	[_children removeAllObjects];
}

-(void) detachChild:(CCNode *)child cleanup:(BOOL)doCleanup
{
	// IMPORTANT:
	//  -1st do onExit
	//  -2nd cleanup
	if (_isInActiveScene)
	{
		[child onExitTransitionDidStart];
		[child onExit];
	}
	
	RecursivelyIncrementPausedAncestors(child, -child->_pausedAncestors);
	child->_pausedAncestors = 0;
	
	// If you don't do cleanup, the child's actions will not get removed and the
	// its scheduledSelectors_ dict will not get released!
	if (doCleanup)
		[child cleanup];

	// set parent nil at the end (issue #476)
	[child setParent:nil];

	[[[CCDirector sharedDirector] responderManager] markAsDirty];

	[_children removeObject:child];
}

// used internally to alter the zOrder variable. DON'T call this method manually
-(void) _setZOrder:(NSInteger) z
{
	_zOrder = z;
}

// helper used by reorderChild & add
-(void) insertChild:(CCNode*)child z:(NSInteger)z
{
	_isReorderChildDirty=YES;

    [_children addObject:child];
	[child _setZOrder:z];
}

-(void) reorderChild:(CCNode*) child z:(NSInteger)z
{
	NSAssert( child != nil, @"Child must be non-nil");

	_isReorderChildDirty = YES;

	[child setOrderOfArrival: globalOrderOfArrival++];
	[child _setZOrder:z];
}

- (NSComparisonResult) compareZOrderToNode:(CCNode*)node
{
    if (node->_zOrder == _zOrder)
    {
        if (node->_orderOfArrival == _orderOfArrival)
        {
            return NSOrderedSame;
        }
        else if (node->_orderOfArrival < _orderOfArrival)
        {
            return NSOrderedDescending;
        }
        else
        {
            return NSOrderedAscending;
        }
    }
    else if (node->_zOrder < _zOrder)
    {
        return NSOrderedDescending;
    }
    else
    {
        return NSOrderedAscending;
    }
}

- (void) sortAllChildren
{
	if (_isReorderChildDirty)
	{
        [_children sortUsingSelector:@selector(compareZOrderToNode:)];

		//don't need to check children recursively, that's done in visit of each child
        
		_isReorderChildDirty = NO;
        
        [[[CCDirector sharedDirector] responderManager] markAsDirty];

	}
}

#pragma mark CCNode Draw

-(void) draw
{
}

-(void) visit
{
	// quick return if not visible. children won't be drawn.
	if (!_visible)
		return;
    
	kmGLPushMatrix();

	[self transform];

	if(_children) {

		[self sortAllChildren];

		NSUInteger i = 0;

		// draw children zOrder < 0
		for( ; i < _children.count; i++ ) {
			CCNode *child = [_children objectAtIndex:i];
			if ( [child zOrder] < 0 )
				[child visit];
			else
				break;
		}

		// self draw
		[self draw];

		// draw children zOrder >= 0
		for( ; i < _children.count; i++ ) {
			CCNode *child = [_children objectAtIndex:i];
			[child visit];
		}

	} else
		[self draw];

	// reset for next frame
	_orderOfArrival = 0;

	kmGLPopMatrix();
}

#pragma mark CCNode - Transformations

-(void) transformAncestors
{
	if( _parent ) {
		[_parent transformAncestors];
		[_parent transform];
	}
}

-(void) transform
{
	kmMat4 transform4x4;

	// Convert 3x3 into 4x4 matrix
	CGAffineTransform tmpAffine = [self nodeToParentTransform];
	CGAffineToGL(&tmpAffine, transform4x4.mat);

	// Update Z vertex manually
	transform4x4.mat[14] = _vertexZ;

	kmGLMultMatrix( &transform4x4 );
}

#pragma mark CCPhysics support.

// Private method used to extract the non-rigid part of the node's transform relative to a CCPhysicsNode.
// This method can only be called in very specific circumstances.
-(CGAffineTransform)nonRigidTransform
{
	CGAffineTransform toPhysics = NodeToPhysicsTransform(self);
	
	CCPhysicsBody *body = GetBodyIfRunning(self);
	if(body){
		return cpTransformMult(cpTransformInverse(body.absoluteTransform), toPhysics);
	} else {
		// Body is not active yet, so this is more of a mess. :-\
		// Need to guess the rigid part of the transform.
		float radians = CC_DEGREES_TO_RADIANS(NodeToPhysicsRotation(self));
		CGAffineTransform absolute = cpTransformRigid(ccp(toPhysics.tx, toPhysics.ty), radians);
		return cpTransformMult(cpTransformInverse(absolute), toPhysics);
	}
}

// Overriden by CCPhysicsNode to return YES.
-(BOOL)isPhysicsNode {return NO;}
-(CCPhysicsNode *)physicsNode {return (self.isPhysicsNode ? (CCPhysicsNode *)self : self.parent.physicsNode);}

-(void)setupPhysicsBody:(CCPhysicsBody *)physicsBody
{
	if(physicsBody){
		CCPhysicsNode *physics = self.physicsNode;
		NSAssert(physics != nil, @"A CCNode with an attached CCPhysicsBody must be added as a descendant of a CCPhysicsNode.");
		
		// Copy the node's rotation first.
		// Otherwise it may cause the position to rotate around a non-zero center of gravity.
		physicsBody.absoluteRadians = CC_DEGREES_TO_RADIANS(NodeToPhysicsRotation(self));
		
		// Grab the origin position of the node from it's transform.
		CGAffineTransform transform = NodeToPhysicsTransform(self);
		physicsBody.absolutePosition = ccp(transform.tx, transform.ty);
		
		cpTransform nonRigid = self.nonRigidTransform;
		[_physicsBody willAddToPhysicsNode:physics nonRigidTransform:nonRigid];
		[physics.space smartAdd:physicsBody];
		
		NSArray *joints = physicsBody.joints;
		for(NSUInteger i=0, count=joints.count; i<count; i++){
			[joints[i] tryAddToPhysicsNode:physics];
		}
		
#ifndef NDEBUG
		// Reset these to zero since they shouldn't be read anyway.
		_position = CGPointZero;
		_rotationalSkewX = _rotationalSkewY = 0.0f;
#endif
	}
}

-(void)teardownPhysics
{
	if(_physicsBody){
		CCPhysicsNode *physics = self.physicsNode;
		NSAssert(physics != nil, @"A CCNode with an attached CCPhysicsBody must be a descendent of a CCPhysicsNode.");
		
		// Copy the positional data back to the ivars.
		_position = self.position;
		_rotationalSkewX = _rotationalSkewY = self.rotation;
		
		NSArray *joints = _physicsBody.joints;
		for(NSUInteger i=0, count=joints.count; i<count; i++){
			[joints[i] tryRemoveFromPhysicsNode:physics];
		}
		
		[physics.space smartRemove:_physicsBody];
		[_physicsBody didRemoveFromPhysicsNode:physics];
	}
}

-(void)setPhysicsBody:(CCPhysicsBody *)physicsBody
{
	if(physicsBody){
		NSAssert(_scaleType == CCScaleTypePoints, @"Currently only 'Points' is supported as a scale type for physics nodes.");
		NSAssert(_rotationalSkewX == _rotationalSkewY, @"Currently physics nodes don't support skewing.");
		NSAssert(_skewX == 0.0 && _skewY == 0.0, @"Currently physics nodes don't support skewing.");
	}
	
	if(physicsBody != _physicsBody){
		if(_isInActiveScene){
			[self teardownPhysics];
			[self setupPhysicsBody:physicsBody];
		}
		
		// nil out the old body's node reference.
		_physicsBody.node = nil;
		
		_physicsBody = physicsBody;
		_physicsBody.node = self;
	}
}

#pragma mark CCNode SceneManagement

// Overriden by CCScene to return YES.
-(BOOL)isScene {return NO;}
-(CCScene *)scene {return (self.isScene ? (CCScene *)self : self.parent.scene);}

-(void) onEnter
{
	[_children makeObjectsPerformSelector:@selector(onEnter)];
	
	[self setupPhysicsBody:_physicsBody];
	
	if(![_scheduler isTargetScheduled:self]){
		[_scheduler scheduleTarget:self];
	}
	
	BOOL wasRunning = self.runningInActiveScene;
	_isInActiveScene = YES;
	[self wasRunning:wasRunning];
}

-(void) onEnterTransitionDidFinish
{
	[_children makeObjectsPerformSelector:@selector(onEnterTransitionDidFinish)];
}

-(void) onExitTransitionDidStart
{
	[_children makeObjectsPerformSelector:@selector(onExitTransitionDidStart)];
}

-(void) onExit
{
	[self teardownPhysics];
	
	BOOL wasRunning = self.runningInActiveScene;
	_isInActiveScene = NO;
	[self wasRunning:wasRunning];
	
	[_children makeObjectsPerformSelector:@selector(onExit)];
}

#pragma mark CCNode Actions

-(void) setActionManager:(CCActionManager *)actionManager
{
	if( actionManager != _actionManager ) {
		[self stopAllActions];

		_actionManager = actionManager;
	}
}

-(CCActionManager*) actionManager
{
	return _actionManager;
}

-(CCAction*) runAction:(CCAction*) action
{
	NSAssert( action != nil, @"Argument must be non-nil");

	[_actionManager addAction:action target:self paused:!self.runningInActiveScene];
	return action;
}

-(void) stopAllActions
{
	[_actionManager removeAllActionsFromTarget:self];
}

-(void) stopAction: (CCAction*) action
{
	[_actionManager removeAction:action];
}

-(void) stopActionByTag:(NSInteger)aTag
{
	NSAssert( aTag != kCCActionTagInvalid, @"Invalid tag");
	[_actionManager removeActionByTag:aTag target:self];
}

-(CCAction*) getActionByTag:(NSInteger) aTag
{
	NSAssert( aTag != kCCActionTagInvalid, @"Invalid tag");
	return 	[_actionManager getActionByTag:aTag target:self];
}

-(NSUInteger) numberOfRunningActions
{
	return [_actionManager numberOfRunningActionsInTarget:self];
}

#pragma mark CCNode - Scheduler

-(NSInteger)priority
{
	return 0;
}

-(CCTimer *) scheduleBlock:(CCTimerBlock)block delay:(CCTime)delay
{
	return [_scheduler scheduleBlock:block forTarget:self withDelay:delay];
}

-(void) setScheduler:(CCScheduler *)scheduler
{
	if( scheduler != _scheduler ) {
		[_scheduler unscheduleTarget:self];

		_scheduler = scheduler;
	}
}

-(CCScheduler*) scheduler
{
	return _scheduler;
}

-(CCTimer *) schedule:(SEL)selector interval:(CCTime)interval
{
	return [self schedule:selector interval:interval repeat:kCCRepeatForever delay:0];
}

-(CCTimer *) schedule:(SEL)selector interval:(CCTime)interval repeat: (uint) repeat delay:(CCTime) delay
{
	NSAssert( selector != nil, @"Argument must be non-nil");
	NSAssert( interval >=0, @"Arguemnt must be positive");
	
	[self unschedule:selector];
	
	void (*imp)(id, SEL, CCTime) = (__typeof(imp))[self methodForSelector:selector];
	CCTimer *timer = [_scheduler scheduleBlock:^(CCTimer *t){
		imp(self, selector, t.deltaTime);
	} forTarget:self withDelay:delay];
	
	timer.repeatCount = CCTimerRepeatForever;
	timer.repeatInterval = interval;
	timer.userData = NSStringFromSelector(selector);
	
	return timer;
}

- (CCTimer *) scheduleOnce:(SEL) selector delay:(CCTime) delay
{
	return [self schedule:selector interval:0.f repeat:0 delay:delay];
}

-(void)unschedule:(SEL)selector
{
	NSString *selectorName = NSStringFromSelector(selector);
	
	for(CCTimer *timer in [_scheduler timersForTarget:self]){
		if([selectorName isEqual:timer.userData]) [timer invalidate];
	}
}

-(void)unscheduleAllSelectors
{
	for(CCTimer *timer in [_scheduler timersForTarget:self]){
		if([timer.userData isKindOfClass:[NSString class]]) [timer invalidate];
	}
}

// Used to pause/unpause a node's actions and timers when it's isRunning state changes.
-(void)wasRunning:(BOOL)wasRunning
{
	BOOL isRunning = self.runningInActiveScene;
	
	if(isRunning && !wasRunning){
		[_scheduler setPaused:NO target:self];
		[_actionManager resumeTarget:self];
	} else if(!isRunning && wasRunning){
		[_scheduler setPaused:YES target:self];
		[_actionManager pauseTarget:self];
	}
}

-(BOOL)isRunningInActiveScene
{
	return (_isInActiveScene && !_paused && _pausedAncestors == 0);
}

- (BOOL)paused
{
    return(_paused);
}

-(void)setPaused:(BOOL)paused
{
	if(_paused != paused){
		BOOL wasRunning = self.runningInActiveScene;
		_paused = paused;
		[self wasRunning:wasRunning];
		
		RecursivelyIncrementPausedAncestors(self, (paused ? 1 : -1));
	}
}

#pragma mark CCNode Transform

- (CGPoint) convertPositionToPoints:(CGPoint)position type:(CCPositionType)type
{
    CCDirector* director = [CCDirector sharedDirector];
    
    CGPoint positionInPoints;
    float x = 0;
    float y = 0;
    
    // Convert position to points
    CCPositionUnit xUnit = type.xUnit;
    if (xUnit == CCPositionUnitPoints) x = position.x;
    else if (xUnit == CCPositionUnitUIPoints) x = position.x * director.UIScaleFactor;
    else if (xUnit == CCPositionUnitNormalized) x = position.x * _parent.contentSizeInPoints.width;
    
    CCPositionUnit yUnit = type.yUnit;
    if (yUnit == CCPositionUnitPoints) y = position.y;
    else if (yUnit == CCPositionUnitUIPoints) y = position.y * director.UIScaleFactor;
    else if (yUnit == CCPositionUnitNormalized) y = position.y * _parent.contentSizeInPoints.height;
    
    // Account for reference corner
    CCPositionReferenceCorner corner = type.corner;
    if (corner == CCPositionReferenceCornerBottomLeft)
    {
        // Nothing needs to be done
    }
    else if (corner == CCPositionReferenceCornerTopLeft)
    {
        // Reverse y-axis
        y = _parent.contentSizeInPoints.height - y;
    }
    else if (corner == CCPositionReferenceCornerTopRight)
    {
        // Reverse x-axis and y-axis
        x = _parent.contentSizeInPoints.width - x;
        y = _parent.contentSizeInPoints.height - y;
    }
    else if (corner == CCPositionReferenceCornerBottomRight)
    {
        // Reverse x-axis
        x = _parent.contentSizeInPoints.width - x;
    }
    
    positionInPoints.x = x;
    positionInPoints.y = y;
    
    return positionInPoints;
}

- (CGPoint) convertPositionFromPoints:(CGPoint)positionInPoints type:(CCPositionType)type
{
    CCDirector* director = [CCDirector sharedDirector];
    
    CGPoint position;
    
    float x = positionInPoints.x;
    float y = positionInPoints.y;
    
    // Account for reference corner
    CCPositionReferenceCorner corner = type.corner;
    if (corner == CCPositionReferenceCornerBottomLeft)
    {
        // Nothing needs to be done
    }
    else if (corner == CCPositionReferenceCornerTopLeft)
    {
        // Reverse y-axis
        y = _parent.contentSizeInPoints.height - y;
    }
    else if (corner == CCPositionReferenceCornerTopRight)
    {
        // Reverse x-axis and y-axis
        x = _parent.contentSizeInPoints.width - x;
        y = _parent.contentSizeInPoints.height - y;
    }
    else if (corner == CCPositionReferenceCornerBottomRight)
    {
        // Reverse x-axis
        x = _parent.contentSizeInPoints.width - x;
    }
    
    // Convert position from points
    CCPositionUnit xUnit = type.xUnit;
    if (xUnit == CCPositionUnitPoints) position.x = x;
    else if (xUnit == CCPositionUnitUIPoints) position.x = x / director.UIScaleFactor;
    else if (xUnit == CCPositionUnitNormalized)
    {
        float parentWidth = _parent.contentSizeInPoints.width;
        if (parentWidth > 0)
        {
            position.x = x / parentWidth;
        }
    }
    
    CCPositionUnit yUnit = type.yUnit;
    if (yUnit == CCPositionUnitPoints) position.y = y;
    else if (yUnit == CCPositionUnitUIPoints) position.y = y / director.UIScaleFactor;
    else if (yUnit == CCPositionUnitNormalized)
    {
        float parentHeight = _parent.contentSizeInPoints.height;
        if (parentHeight > 0)
        {
            position.y = y / parentHeight;
        }
    }
    
    return position;
}

- (CGPoint) positionInPoints
{
    return [self convertPositionToPoints:self.position type:_positionType];
}

- (CGAffineTransform)nodeToParentTransform
{
	CCPhysicsBody *physicsBody = GetBodyIfRunning(self);
	if(physicsBody){
		CGAffineTransform rigidTransform = RigidBodyToParentTransform(self, physicsBody);
		_transform = cpTransformMult(rigidTransform, cpTransformScale(_scaleX, _scaleY));
	} else if ( _isTransformDirty ) {
        
        // Get content size
        CGSize contentSizeInPoints;
        if (CCSizeTypeIsBasicPoints(_contentSizeType))
        {
            // Optimization for basic content sizes (most common case)
            contentSizeInPoints = _contentSize;
        }
        else
        {
            contentSizeInPoints = self.contentSizeInPoints;
        }
        
        // Calculate the anchor point in points
        _anchorPointInPoints = ccp( contentSizeInPoints.width * _anchorPoint.x, contentSizeInPoints.height * _anchorPoint.y );
        
        // Convert position to points
        CGPoint positionInPoints;
        if (CCPositionTypeIsBasicPoints(_positionType))
        {
            // Optimization for basic points (most common case)
            positionInPoints = _position;
        }
        else
        {
            positionInPoints = [self convertPositionToPoints:_position type:_positionType];
        }
        
        // Get x and y
		float x = positionInPoints.x;
		float y = positionInPoints.y;
        
		// Rotation values
		// Change rotation code to handle X and Y
		// If we skew with the exact same value for both x and y then we're simply just rotating
		float cx = 1, sx = 0, cy = 1, sy = 0;
		if( _rotationalSkewX || _rotationalSkewY ) {
			float radiansX = -CC_DEGREES_TO_RADIANS(_rotationalSkewX);
			float radiansY = -CC_DEGREES_TO_RADIANS(_rotationalSkewY);
			cx = cosf(radiansX);
			sx = sinf(radiansX);
			cy = cosf(radiansY);
			sy = sinf(radiansY);
		}

		BOOL needsSkewMatrix = ( _skewX || _skewY );
        
        float scaleFactor = 1;
        if (_scaleType == CCScaleTypeScaled) scaleFactor = [CCDirector sharedDirector].UIScaleFactor;

		// optimization:
		// inline anchor point calculation if skew is not needed
		// Adjusted transform calculation for rotational skew
		if( !needsSkewMatrix && !CGPointEqualToPoint(_anchorPointInPoints, CGPointZero) ) {
			x += cy * -_anchorPointInPoints.x * _scaleX * scaleFactor + -sx * -_anchorPointInPoints.y * _scaleY;
			y += sy * -_anchorPointInPoints.x * _scaleX * scaleFactor +  cx * -_anchorPointInPoints.y * _scaleY;
		}


		// Build Transform Matrix
		// Adjusted transfor m calculation for rotational skew
		_transform = CGAffineTransformMake( cy * _scaleX * scaleFactor, sy * _scaleX * scaleFactor,
										   -sx * _scaleY * scaleFactor, cx * _scaleY * scaleFactor,
										   x, y );

		// XXX: Try to inline skew
		// If skew is needed, apply skew and then anchor point
		if( needsSkewMatrix ) {
			CGAffineTransform skewMatrix = CGAffineTransformMake(1.0f, tanf(CC_DEGREES_TO_RADIANS(_skewY)),
																 tanf(CC_DEGREES_TO_RADIANS(_skewX)), 1.0f,
																 0.0f, 0.0f );
			_transform = CGAffineTransformConcat(skewMatrix, _transform);

			// adjust anchor point
			if( ! CGPointEqualToPoint(_anchorPointInPoints, CGPointZero) )
				_transform = CGAffineTransformTranslate(_transform, -_anchorPointInPoints.x, -_anchorPointInPoints.y);
		}

		_isTransformDirty = NO;
	}

	return _transform;
}

- (CGAffineTransform)parentToNodeTransform
{
	// TODO Need to find a better way to mark physics transforms as dirty
	if ( _isInverseDirty || GetBodyIfRunning(self) ) {
		_inverse = CGAffineTransformInvert([self nodeToParentTransform]);
		_isInverseDirty = NO;
	}

	return _inverse;
}

- (CGAffineTransform)nodeToWorldTransform
{
	CGAffineTransform t = [self nodeToParentTransform];

	for (CCNode *p = _parent; p != nil; p = p.parent)
		t = CGAffineTransformConcat(t, [p nodeToParentTransform]);

	return t;
}

- (CGAffineTransform)worldToNodeTransform
{
	return CGAffineTransformInvert([self nodeToWorldTransform]);
}

- (CGPoint)convertToNodeSpace:(CGPoint)worldPoint
{
	CGPoint ret = CGPointApplyAffineTransform(worldPoint, [self worldToNodeTransform]);
	return ret;
}

- (CGPoint)convertToWorldSpace:(CGPoint)nodePoint
{
	CGPoint ret = CGPointApplyAffineTransform(nodePoint, [self nodeToWorldTransform]);
	return ret;
}

- (CGPoint)convertToNodeSpaceAR:(CGPoint)worldPoint
{
	CGPoint nodePoint = [self convertToNodeSpace:worldPoint];
	return ccpSub(nodePoint, _anchorPointInPoints);
}

- (CGPoint)convertToWorldSpaceAR:(CGPoint)nodePoint
{
	nodePoint = ccpAdd(nodePoint, _anchorPointInPoints);
	return [self convertToWorldSpace:nodePoint];
}

- (CGPoint)convertToWindowSpace:(CGPoint)nodePoint
{
    CGPoint worldPoint = [self convertToWorldSpace:nodePoint];
	return [[CCDirector sharedDirector] convertToUI:worldPoint];
}

// -----------------------------------------------------------------
#pragma mark - touch interface
// -----------------------------------------------------------------

/** Returns YES, if touch is inside sprite
 Added hit area expansion / contraction
 */
- (BOOL)hitTestWithWorldPos:(CGPoint)pos
{
    pos = [self convertToNodeSpace:pos];
    CGPoint offset = ccp(-_hitAreaExpansion, -_hitAreaExpansion);
    CGSize size = CGSizeMake(self.contentSizeInPoints.width - offset.x, self.contentSizeInPoints.height - offset.y);
    if ((pos.y < offset.y) || (pos.y > size.height) || (pos.x < offset.x) || (pos.x > size.width)) return(NO);
    
    return(YES);
}

// -----------------------------------------------------------------


#pragma mark - CCColor methods

@synthesize cascadeColorEnabled=_cascadeColorEnabled;
@synthesize cascadeOpacityEnabled=_cascadeOpacityEnabled;

-(CGFloat) opacity
{
	return _color.a;
}

-(CGFloat) displayedOpacity
{
	return _displayColor.a;
}

- (void) setOpacity:(CGFloat)opacity
{
	_displayColor.a = _color.a = opacity;
	[self cascadeOpacityIfNeeded];
}

-(CCColor*) color
{
	return [CCColor colorWithCcColor4f:_color];
}

-(CCColor*) displayedColor
{
	return [CCColor colorWithCcColor4f:_displayColor];
}


- (void) setColor:(CCColor*)color
{
	// Retain old alpha.
	float alpha = _color.a;
	_displayColor = _color = color.ccColor4f;
	_displayColor.a = _color.a = alpha;
	
	[self cascadeColorIfNeeded];
}

-(CCColor*) colorRGBA
{
	return [CCColor colorWithCcColor4f:_color];
}

- (void) setColorRGBA:(CCColor*)color
{
	// apply the new alpha too.
	_displayColor = _color = color.ccColor4f;
	
	[self cascadeColorIfNeeded];
	[self cascadeOpacityIfNeeded];
}


- (void) cascadeColorIfNeeded
{
	if( _cascadeColorEnabled ) {
		CCColor* parentColor = [CCColor whiteColor];
		if( _parent.isCascadeColorEnabled )
			parentColor = [_parent displayedColor];
		[self updateDisplayedColor:parentColor.ccColor4f];
	}
}

// Used internally to recurse through children, thus the parameter is not a CCColor*
- (void)updateDisplayedColor:(ccColor4F) parentColor
{
	_displayColor.r = _color.r * parentColor.r;
	_displayColor.g = _color.g * parentColor.g;
	_displayColor.b = _color.b * parentColor.b;
	
	if (_cascadeColorEnabled) {
		for (CCNode* item in _children) {
			[item updateDisplayedColor:_displayColor];
		}
	}
}

- (void) cascadeOpacityIfNeeded
{
	if( _cascadeOpacityEnabled ) {
		GLfloat parentOpacity = 1.0f;
		if( [_parent isCascadeOpacityEnabled] )
			parentOpacity = [_parent displayedOpacity];
		[self updateDisplayedOpacity:parentOpacity];
	}
}

- (void)updateDisplayedOpacity:(CGFloat)parentOpacity
{
	_displayColor.a = _color.a * parentOpacity;
	
	if (_cascadeOpacityEnabled) {
		for (CCNode* item in _children) {
			[item updateDisplayedOpacity:_displayColor.a];
		}
	}
}

-(void) setOpacityModifyRGB:(BOOL)boolean{
	// Ignored in CCNode. Implemented in subclasses
}

-(BOOL) doesOpacityModifyRGB{
	return NO; // Subclasses may use this feature.
}


@end
