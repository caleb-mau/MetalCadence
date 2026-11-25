#import "MCWorkloadProfile.h"
#import <math.h>
@implementation MCWorkloadProfile
-(instancetype)init{if((self=[super init])){_kind=MCWorkloadKindInteractiveGame;_policy=MCFramePolicyMinimumBoost;_producer=MCProducerKindExternalCapture;_sourceFPS=30;_displayFPS=60;_minimumFreshFPS=31;_preferredFreshFPS=60;}return self;}
+(instancetype)interactiveGameWithSourceFPS:(double)sourceFPS displayFPS:(double)displayFPS{MCWorkloadProfile *p=[self new];p.sourceFPS=sourceFPS;p.displayFPS=displayFPS;p.minimumFreshFPS=sourceFPS+1;p.preferredFreshFPS=MIN(displayFPS,sourceFPS*2);return p;}
-(id)copyWithZone:(NSZone*)zone{MCWorkloadProfile *p=[MCWorkloadProfile new];p.kind=_kind;p.policy=_policy;p.producer=_producer;p.sourceFPS=_sourceFPS;p.displayFPS=_displayFPS;p.minimumFreshFPS=_minimumFreshFPS;p.preferredFreshFPS=_preferredFreshFPS;return p;}
@end
@implementation MCWorkloadPlan
-(instancetype)initWithProfile:(MCWorkloadProfile*)profile{
 if(!(self=[super init]))return nil;
 double source=isfinite(profile.sourceFPS)?MAX(1,profile.sourceFPS):30;
 double display=isfinite(profile.displayFPS)?MAX(24,profile.displayFPS):60;
 double minimum=isfinite(profile.minimumFreshFPS)&&profile.minimumFreshFPS>0?profile.minimumFreshFPS:source+1;
 double preferred=isfinite(profile.preferredFreshFPS)&&profile.preferredFreshFPS>0?profile.preferredFreshFPS:MIN(display,source*2);
 _minimumFreshFPS=MIN(minimum,display);
 double goal=MAX(source,MIN(display,preferred));
 switch(profile.policy){
 case MCFramePolicyEnergySaver: goal=source;break;
 case MCFramePolicyLowestLatency: goal=MAX(source,MIN(goal,source*2));break;
 case MCFramePolicyMinimumBoost: goal=MAX(source,MIN(display,MAX(goal,minimum)));break;
 case MCFramePolicySmooth: goal=MAX(source,MIN(goal,display));break;
 case MCFramePolicyMaximumThroughput: goal=MAX(goal,MIN(display,source*4));break;
 }
 _multiplier=goal<=source+0.01?1:goal<=source*2.05?2:4;
 _targetFreshFPS=MIN(display,source*_multiplier);
 double frame=1./source;
 if(profile.kind==MCWorkloadKindRemoteDesktop||profile.policy==MCFramePolicyLowestLatency){_minimumDelay=.006;_initialDelay=MAX(.016,frame*.7);_maximumDelay=.090;}
 else if(profile.policy==MCFramePolicySmooth||profile.kind==MCWorkloadKindLiveProduction){_minimumDelay=.022;_initialDelay=MAX(.045,frame*1.5);_maximumDelay=.150;}
 else if(profile.policy==MCFramePolicyEnergySaver){_minimumDelay=.008;_initialDelay=MAX(.020,frame);_maximumDelay=.100;}
 else {_minimumDelay=.012;_initialDelay=MAX(.025,frame*1.2);_maximumDelay=.125;}
 _initialDelay=MIN(_maximumDelay,_initialDelay);_adaptiveLatency=profile.policy!=MCFramePolicyEnergySaver;
 return self;
}
@end
