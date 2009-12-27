//
//  PBGitRepository.m
//  GitTest
//
//  Created by Pieter de Bie on 13-06-08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "PBGitRepository.h"
#import "PBGitCommit.h"
#import "PBGitWindowController.h"
#import "PBGitBinary.h"

#import "NSFileHandleExt.h"
#import "PBEasyPipe.h"
#import "PBGitRef.h"
#import "PBGitRevSpecifier.h"

NSString* PBGitRepositoryErrorDomain = @"GitXErrorDomain";

@implementation PBGitRepository

@synthesize revisionList, branches, currentBranch, refs, hasChanged, config;

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
	if (outError) {
		*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain
                                      code:0
                                  userInfo:[NSDictionary dictionaryWithObject:@"Reading files is not supported." forKey:NSLocalizedFailureReasonErrorKey]];
	}
	return NO;
}

+ (BOOL) isBareRepository: (NSString*) path
{
	return [[PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:[NSArray arrayWithObjects:@"rev-parse", @"--is-bare-repository", nil] inDir:path] isEqualToString:@"true"];
}

+ (NSURL*)gitDirForURL:(NSURL*)repositoryURL;
{
	if (![PBGitBinary path])
		return nil;

	NSString* repositoryPath = [repositoryURL path];

	if ([self isBareRepository:repositoryPath])
		return repositoryURL;


	// Use rev-parse to find the .git dir for the repository being opened
	NSString* newPath = [PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:[NSArray arrayWithObjects:@"rev-parse", @"--git-dir", nil] inDir:repositoryPath];
	if ([newPath isEqualToString:@".git"])
		return [NSURL fileURLWithPath:[repositoryPath stringByAppendingPathComponent:@".git"]];
	if ([newPath length] > 0)
		return [NSURL fileURLWithPath:newPath];

	return nil;
}

// For a given path inside a repository, return either the .git dir
// (for a bare repo) or the directory above the .git dir otherwise
+ (NSURL*)baseDirForURL:(NSURL*)repositoryURL;
{
	NSURL* gitDirURL         = [self gitDirForURL:repositoryURL];
	NSString* repositoryPath = [gitDirURL path];

	if (![self isBareRepository:repositoryPath]) {
		repositoryURL = [NSURL fileURLWithPath:[[repositoryURL path] stringByDeletingLastPathComponent]];
	}

	return repositoryURL;
}

// NSFileWrapper is broken and doesn't work when called on a directory containing a large number of directories and files.
//because of this it is safer to implement readFromURL than readFromFileWrapper.
//Because NSFileManager does not attempt to recursively open all directories and file when fileExistsAtPath is called
//this works much better.
- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
	if (![PBGitBinary path])
	{
		if (outError) {
			NSDictionary* userInfo = [NSDictionary dictionaryWithObject:[PBGitBinary notFoundError]
																 forKey:NSLocalizedRecoverySuggestionErrorKey];
			*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain code:0 userInfo:userInfo];
		}
		return NO;
	}

	BOOL isDirectory = FALSE;
	[[NSFileManager defaultManager] fileExistsAtPath:[absoluteURL path] isDirectory:&isDirectory];
	if (!isDirectory) {
		if (outError) {
			NSDictionary* userInfo = [NSDictionary dictionaryWithObject:@"Reading files is not supported."
																 forKey:NSLocalizedRecoverySuggestionErrorKey];
			*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain code:0 userInfo:userInfo];
		}
		return NO;
	}


	NSURL* gitDirURL = [PBGitRepository gitDirForURL:[self fileURL]];
	if (!gitDirURL) {
		if (outError) {
			NSDictionary* userInfo = [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"%@ does not appear to be a git repository.", [self fileName]]
																 forKey:NSLocalizedRecoverySuggestionErrorKey];
			*outError = [NSError errorWithDomain:PBGitRepositoryErrorDomain code:0 userInfo:userInfo];
		}
		return NO;
	}

	[self setFileURL:gitDirURL];
	[self setup];
	[self readCurrentBranch];
	return YES;
}

- (void) setup
{
	config = [[PBGitConfig alloc] initWithRepositoryPath:[[self fileURL] path]];
	self.branches = [NSMutableArray array];
	[self reloadRefs];
	revisionList = [[PBGitRevList alloc] initWithRepository:self];
}

- (id) initWithURL: (NSURL*) path
{
	if (![PBGitBinary path])
		return nil;

	NSURL* gitDirURL = [PBGitRepository gitDirForURL:path];
	if (!gitDirURL)
		return nil;

	self = [self init];
	[self setFileURL: gitDirURL];

	[self setup];
	
	// We don't want the window controller to display anything yet..
	// We'll leave that to the caller of this method.
#ifndef CLI
	[self addWindowController:[[PBGitWindowController alloc] initWithRepository:self displayDefault:NO]];
#endif

	[self showWindows];

	return self;
}

// The fileURL the document keeps is to the .git dir, but that’s pretty
// useless for display in the window title bar, so we show the directory above
- (NSString*)displayName
{
	NSString* dirName = self.fileURL.path.lastPathComponent;
	if ([dirName isEqualToString:@".git"])
		dirName = [self.fileURL.path stringByDeletingLastPathComponent].lastPathComponent;
	NSString* displayName;
	if (![[PBGitRef refFromString:[[self headRef] simpleRef]] type]) {
		displayName = [NSString stringWithFormat:@"%@ (detached HEAD)", dirName];
	} else {
		displayName = [NSString stringWithFormat:@"%@ (branch: %@)", dirName,
					 [[self headRef] description]];
	}

	return displayName;
}

// Get the .gitignore file at the root of the repository
- (NSString*)gitIgnoreFilename
{
	return [[self workingDirectory] stringByAppendingPathComponent:@".gitignore"];
}

- (BOOL)isBareRepository
{
	if([self workingDirectory]) {
		return [PBGitRepository isBareRepository:[self workingDirectory]];
	} else {
		return true;
	}
}

// Overridden to create our custom window controller
- (void)makeWindowControllers
{
#ifndef CLI
	[self addWindowController: [[PBGitWindowController alloc] initWithRepository:self displayDefault:YES]];
#endif
}

- (PBGitWindowController *)windowController
{
	if ([[self windowControllers] count] == 0)
		return NULL;
	
	return [[self windowControllers] objectAtIndex:0];
}

- (void) addRef: (PBGitRef *) ref fromParameters: (NSArray *) components
{
	NSString* type = [components objectAtIndex:1];

	NSString* sha;
	if ([type isEqualToString:@"tag"] && [components count] == 4)
		sha = [components objectAtIndex:3];
	else
		sha = [components objectAtIndex:2];

	NSMutableArray* curRefs;
	if (curRefs = [refs objectForKey:sha])
		[curRefs addObject:ref];
	else
		[refs setObject:[NSMutableArray arrayWithObject:ref] forKey:sha];
}

// reloadRefs: reload all refs in the repository, like in readRefs
// To stay compatible, this does not remove a ref from the branches list
// even after it has been deleted.
// returns YES when a ref was changed
- (BOOL) reloadRefs
{
	_headRef = nil;
	BOOL ret = NO;

	refs = [NSMutableDictionary dictionary];

	NSString* output = [PBEasyPipe outputForCommand:[PBGitBinary path]
										   withArgs:[NSArray arrayWithObjects:@"for-each-ref", @"--format=%(refname) %(objecttype) %(objectname)"
													 " %(*objectname)", @"refs", nil]
											  inDir: self.fileURL.path];
	NSArray* lines = [output componentsSeparatedByString:@"\n"];

	for (NSString* line in lines) {
		// If its an empty line, skip it (e.g. with empty repositories)
		if ([line length] == 0)
			continue;

		NSArray* components = [line componentsSeparatedByString:@" "];

		// First do the ref matching. If this ref is new, add it to our ref list
		PBGitRef *newRef = [PBGitRef refFromString:[components objectAtIndex:0]];
		PBGitRevSpecifier* revSpec = [[PBGitRevSpecifier alloc] initWithRef:newRef];
		if ([self addBranch:revSpec] != revSpec)
			ret = YES;

		// Also add this ref to the refs list
		[self addRef:newRef fromParameters:components];
	}

	// Add an "All branches" option in the branches list
	[self addBranch:[PBGitRevSpecifier allBranchesRevSpec]];
	[self addBranch:[PBGitRevSpecifier localBranchesRevSpec]];

	[[[self windowController] window] setTitle:[self displayName]];

	return ret;
}

- (void) lazyReload
{
	if (!hasChanged)
		return;

	[self reloadRefs];
	[self.revisionList reload];
	hasChanged = NO;
}

- (PBGitRevSpecifier *)headRef
{
	if (_headRef)
		return _headRef;

	NSString* branch = [self parseSymbolicReference: @"HEAD"];
	if (branch && [branch hasPrefix:@"refs/heads/"])
		_headRef = [[PBGitRevSpecifier alloc] initWithRef:[PBGitRef refFromString:branch]];
	else
		_headRef = [[PBGitRevSpecifier alloc] initWithRef:[PBGitRef refFromString:@"HEAD"]];

	return _headRef;
}

- (NSString *) headSHA
{
	return [self shaForRef:[[self headRef] ref]];
}

- (PBGitCommit *) headCommit
{
	return [self commitForSHA:[self headSHA]];
}

- (NSString *) shaForRef:(PBGitRef *)ref
{
	if (!ref)
		return nil;

	for (NSString *sha in refs)
		for (PBGitRef *existingRef in [refs objectForKey:sha])
			if ([existingRef isEqualToRef:ref])
				return sha;

	int retValue = 1;
	NSArray *args = [NSArray arrayWithObjects:@"rev-list", @"-1", [ref ref], nil];
	NSString *shaForRef = [self outputInWorkdirForArguments:args retValue:&retValue];
	if (retValue || [shaForRef isEqualToString:@""])
		return nil;

	return shaForRef;
}

- (PBGitCommit *) commitForRef:(PBGitRef *)ref
{
	if (!ref)
		return nil;

	return [self commitForSHA:[self shaForRef:ref]];
}

- (PBGitCommit *) commitForSHA:(NSString *)sha
{
	if (!sha)
		return nil;
	NSArray *revList = [self.revisionList.commits copy];

	for (PBGitCommit *commit in revList)
		if ([[commit realSha] isEqualToString:sha])
			return commit;

	return nil;
}

- (BOOL) isSHAOnHeadBranch:(NSString *)testSHA
{
	if (!testSHA)
		return NO;

	NSString *headSHA = [self headSHA];

	if ([testSHA isEqualToString:headSHA])
		return YES;

	NSString *commitRange = [NSString stringWithFormat:@"%@..%@", testSHA, headSHA];
	NSString *parentsOutput = [self outputForArguments:[NSArray arrayWithObjects:@"rev-list", @"--parents", @"-1", commitRange, nil]];
	if ([parentsOutput isEqualToString:@""]) {
		return NO;
	}

	NSString *mergeSHA = [self outputForArguments:[NSArray arrayWithObjects:@"merge-base", testSHA, headSHA, nil]];
	if ([mergeSHA isEqualToString:testSHA] || [mergeSHA isEqualToString:headSHA])
		return YES;

	return NO;
}

- (BOOL) isRefOnHeadBranch:(PBGitRef *)testRef
{
	if (!testRef)
		return NO;

	return [self isSHAOnHeadBranch:[self shaForRef:testRef]];
}

- (BOOL) checkRefFormat:(NSString *)refName
{
	int retValue = 1;
	[self outputInWorkdirForArguments:[NSArray arrayWithObjects:@"check-ref-format", refName, nil] retValue:&retValue];
	if (retValue)
		return NO;
	return YES;
}

- (BOOL) refExists:(PBGitRef *)ref
{
	int retValue = 1;
    NSString *output = [self outputInWorkdirForArguments:[NSArray arrayWithObjects:@"for-each-ref", [ref ref], nil] retValue:&retValue];
    if (retValue || [output isEqualToString:@""])
        return NO;
    return YES;
}
		
// Returns either this object, or an existing, equal object
- (PBGitRevSpecifier*) addBranch: (PBGitRevSpecifier*) rev
{
	if ([[rev parameters] count] == 0)
		rev = [self headRef];

	// First check if the branch doesn't exist already
	for (PBGitRevSpecifier* r in branches)
		if ([rev isEqualTo: r])
			return r;

	[self willChangeValueForKey:@"branches"];
	[branches addObject: rev];
	[self didChangeValueForKey:@"branches"];
	return rev;
}

- (BOOL)removeBranch:(PBGitRevSpecifier *)rev
{
	for (PBGitRevSpecifier *r in branches) {
		if ([rev isEqualTo:r]) {
			[self willChangeValueForKey:@"branches"];
			[branches removeObject:r];
			[self didChangeValueForKey:@"branches"];
			return TRUE;
		}
	}
	return FALSE;
}
	
- (void) readCurrentBranch
{
		self.currentBranch = [self addBranch: [self headRef]];
}

- (NSString *) workingDirectory
{
	if ([self.fileURL.path hasSuffix:@"/.git"])
		return [self.fileURL.path substringToIndex:[self.fileURL.path length] - 5];
	else if ([[self outputForCommand:@"rev-parse --is-inside-work-tree"] isEqualToString:@"true"])
		return [PBGitBinary path];
	
	return nil;
}

#pragma mark Repository commands

- (BOOL) checkoutRefish:(id <PBGitRefish>)ref
{
	NSString *refName = nil;
	if ([ref refishType] == kGitXBranchType)
		refName = [ref shortName];
	else
		refName = [ref refishName];

	int retValue = 1;
	NSArray *arguments = [NSArray arrayWithObjects:@"checkout", refName, nil];
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *message = [NSString stringWithFormat:@"There was an error checking out the %@ '%@'.\n\nPerhaps your working directory is not clean?", [ref refishType], [ref shortName]];
		[self.windowController showErrorSheetTitle:@"Checkout failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self reloadRefs];
	[self readCurrentBranch];
	return YES;
}

- (BOOL) checkoutFiles:(NSArray *)files fromRefish:(id <PBGitRefish>)ref
{
	if (!files || ([files count] == 0))
		return NO;

	NSString *refName = nil;
	if ([ref refishType] == kGitXBranchType)
		refName = [ref shortName];
	else
		refName = [ref refishName];

	int retValue = 1;
	NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"checkout", refName, @"--", nil];
	[arguments addObjectsFromArray:files];
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *message = [NSString stringWithFormat:@"There was an error checking out the file(s) from the %@ '%@'.\n\nPerhaps your working directory is not clean?", [ref refishType], [ref shortName]];
		[self.windowController showErrorSheetTitle:@"Checkout failed!" message:message arguments:arguments output:output];
		return NO;
	}

	return YES;
}


- (BOOL) mergeWithRefish:(id <PBGitRefish>)ref
{
	NSString *refName = [ref refishName];

	int retValue = 1;
	NSArray *arguments = [NSArray arrayWithObjects:@"merge", refName, nil];
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *headName = [[[self headRef] ref] shortName];
		NSString *message = [NSString stringWithFormat:@"There was an error merging %@ into %@.", refName, headName];
		[self.windowController showErrorSheetTitle:@"Merge failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self reloadRefs];
	[self readCurrentBranch];
	return YES;
}

- (BOOL) cherryPickRefish:(id <PBGitRefish>)ref
{
	if (!ref)
		return NO;

	NSString *refName = [ref refishName];

	int retValue = 1;
	NSArray *arguments = [NSArray arrayWithObjects:@"cherry-pick", refName, nil];
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *message = [NSString stringWithFormat:@"There was an error cherry picking the %@ '%@'.\n\nPerhaps your working directory is not clean?", [ref refishType], [ref shortName]];
		[self.windowController showErrorSheetTitle:@"Cherry pick failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self reloadRefs];
	[self readCurrentBranch];
	return YES;
}

- (BOOL) createBranch:(NSString *)branchName atRefish:(id <PBGitRefish>)ref
{
	if (!branchName || !ref)
		return NO;

	int retValue = 1;
	NSArray *arguments = [NSArray arrayWithObjects:@"branch", branchName, [ref refishName], nil];
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *message = [NSString stringWithFormat:@"There was an error creating the branch '%@' at %@ '%@'.", branchName, [ref refishType], [ref shortName]];
		[self.windowController showErrorSheetTitle:@"Create Branch failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self reloadRefs];
	return YES;
}

- (BOOL) createTag:(NSString *)tagName message:(NSString *)message atRefish:(id <PBGitRefish>)target
{
	if (!tagName)
		return NO;

	NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"tag"];

	// if there is a message then make this an annotated tag
	if (message && ![message isEqualToString:@""] && ([message length] > 3)) {
		[arguments addObject:@"-a"];
		[arguments addObject:[@"-m" stringByAppendingString:message]];
	}

	[arguments addObject:tagName];

	// if no refish then git will add it to HEAD
	if (target)
		[arguments addObject:[target refishName]];

	int retValue = 1;
	NSString *output = [self outputInWorkdirForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *targetName = @"HEAD";
		if (target)
			targetName = [NSString stringWithFormat:@"%@ '%@'", [target refishType], [target shortName]];
		NSString *message = [NSString stringWithFormat:@"There was an error creating the tag '%@' at %@.", tagName, targetName];
		[self.windowController showErrorSheetTitle:@"Create Tag failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self reloadRefs];
	return YES;
}

- (BOOL) deleteRef:(PBGitRef *)ref
{
	if (!ref)
		return NO;

	int retValue = 1;
	NSArray *arguments = [NSArray arrayWithObjects:@"update-ref", @"-d", [ref ref], nil];
	NSString * output = [self outputForArguments:arguments retValue:&retValue];
	if (retValue) {
		NSString *message = [NSString stringWithFormat:@"There was an error deleting the ref: %@\n\n", [ref shortName]];
		[self.windowController showErrorSheetTitle:@"Delete ref failed!" message:message arguments:arguments output:output];
		return NO;
	}

	[self removeBranch:[[PBGitRevSpecifier alloc] initWithRef:ref]];
	PBGitCommit *commit = [self commitForRef:ref];
	[commit removeRef:ref];

	[self reloadRefs];
	return YES;
}


#pragma mark low level

- (int) returnValueForCommand:(NSString *)cmd
{
	int i;
	[self outputForCommand:cmd retValue: &i];
	return i;
}

- (NSFileHandle*) handleForArguments:(NSArray *)args
{
	NSString* gitDirArg = [@"--git-dir=" stringByAppendingString:self.fileURL.path];
	NSMutableArray* arguments =  [NSMutableArray arrayWithObject: gitDirArg];
	[arguments addObjectsFromArray: args];
	return [PBEasyPipe handleForCommand:[PBGitBinary path] withArgs:arguments];
}

- (NSFileHandle*) handleInWorkDirForArguments:(NSArray *)args
{
	NSString* gitDirArg = [@"--git-dir=" stringByAppendingString:self.fileURL.path];
	NSMutableArray* arguments =  [NSMutableArray arrayWithObject: gitDirArg];
	[arguments addObjectsFromArray: args];
	return [PBEasyPipe handleForCommand:[PBGitBinary path] withArgs:arguments inDir:[self workingDirectory]];
}

- (NSFileHandle*) handleForCommand:(NSString *)cmd
{
	NSArray* arguments = [cmd componentsSeparatedByString:@" "];
	return [self handleForArguments:arguments];
}

- (NSString*) outputForCommand:(NSString *)cmd
{
	NSArray* arguments = [cmd componentsSeparatedByString:@" "];
	return [self outputForArguments: arguments];
}

- (NSString*) outputForCommand:(NSString *)str retValue:(int *)ret;
{
	NSArray* arguments = [str componentsSeparatedByString:@" "];
	return [self outputForArguments: arguments retValue: ret];
}

- (NSString*) outputForArguments:(NSArray*) arguments
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:arguments inDir: self.fileURL.path];
}

- (NSString*) outputInWorkdirForArguments:(NSArray*) arguments
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:arguments inDir: [self workingDirectory]];
}

- (NSString*) outputInWorkdirForArguments:(NSArray *)arguments retValue:(int *)ret
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:arguments inDir:[self workingDirectory] retValue: ret];
}

- (NSString*) outputForArguments:(NSArray *)arguments retValue:(int *)ret
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path] withArgs:arguments inDir: self.fileURL.path retValue: ret];
}

- (NSString*) outputForArguments:(NSArray *)arguments inputString:(NSString *)input retValue:(int *)ret
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path]
							   withArgs:arguments
								  inDir:[self workingDirectory]
							inputString:input
							   retValue: ret];
}

- (NSString *)outputForArguments:(NSArray *)arguments inputString:(NSString *)input byExtendingEnvironment:(NSDictionary *)dict retValue:(int *)ret
{
	return [PBEasyPipe outputForCommand:[PBGitBinary path]
							   withArgs:arguments
								  inDir:[self workingDirectory]
				 byExtendingEnvironment:dict
							inputString:input
							   retValue: ret];
}

- (BOOL)executeHook:(NSString *)name output:(NSString **)output
{
	return [self executeHook:name withArgs:[NSArray array] output:output];
}

- (BOOL)executeHook:(NSString *)name withArgs:(NSArray *)arguments output:(NSString **)output
{
	NSString *hookPath = [[[[self fileURL] path] stringByAppendingPathComponent:@"hooks"] stringByAppendingPathComponent:name];
	if (![[NSFileManager defaultManager] isExecutableFileAtPath:hookPath])
		return TRUE;

	NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
		[self fileURL].path, @"GIT_DIR",
		[[self fileURL].path stringByAppendingPathComponent:@"index"], @"GIT_INDEX_FILE",
		nil
	];

	int ret = 1;
	NSString *_output =	[PBEasyPipe outputForCommand:hookPath withArgs:arguments inDir:[self workingDirectory] byExtendingEnvironment:info inputString:nil retValue:&ret];

	if (output)
		*output = _output;

	return ret == 0;
}

- (NSString *)parseReference:(NSString *)reference
{
	int ret = 1;
	NSString *ref = [self outputForArguments:[NSArray arrayWithObjects: @"rev-parse", @"--verify", reference, nil] retValue: &ret];
	if (ret)
		return nil;

	return ref;
}

- (NSString*) parseSymbolicReference:(NSString*) reference
{
	NSString* ref = [self outputForArguments:[NSArray arrayWithObjects: @"symbolic-ref", @"-q", reference, nil]];
	if ([ref hasPrefix:@"refs/"])
		return ref;

	return nil;
}

- (void) finalize
{
	NSLog(@"Dealloc of repository");
	[super finalize];
}
@end
