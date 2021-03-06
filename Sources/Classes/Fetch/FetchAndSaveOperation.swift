//
//  FetchAndSaveOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

public class FetchAndSaveOperation: Operation {
	
	private static let allDatabases = [
//		CKContainer.default().publicCloudDatabase,
		CKContainer.default().privateCloudDatabase,
		CKContainer.default().sharedCloudDatabase
	]
	
	public typealias NotificationUserInfo = [AnyHashable : Any]
	
	private let tokens: Tokens
	private let databases: [CKDatabase]
	private let persistentContainer: NSPersistentContainer
	
	/// Called every time if error occurs
	public var errorBlock: ErrorBlock?
	
	private let fetchOperationQueue = OperationQueue()
	private let coreDataOperationQueue = OperationQueue()
	
	public init(from databases: [CKDatabase] = FetchAndSaveOperation.allDatabases, persistentContainer: NSPersistentContainer, tokens: Tokens = CloudCore.tokens) {
		self.tokens = tokens
		self.databases = databases
		self.persistentContainer = persistentContainer
		
		fetchOperationQueue.name = "CloudCoreFetchFromCloud"
		coreDataOperationQueue.name = "CloudCoreFetchFromCloud CoreData"
		coreDataOperationQueue.maxConcurrentOperationCount = 1
	}
		
	override public func main() {
		if self.isCancelled { return }
		
		// Check if CloudCore is initially setupped
		if !SetupOperation.isFinishedBefore {
			let setupOperation = SetupOperation()
			setupOperation.errorBlock = errorBlock
			setupOperation.start()
		}

		NotificationCenter.default.post(name: .CloudCoreWillSyncFromCloud, object: nil)
		
		let backgroundContext = persistentContainer.newBackgroundContext()
		backgroundContext.name = CloudCore.config.contextName
		
		for database in self.databases {
			// It will subadd fetch and save operations to queue
			self.addFetchDatabaseChangesOperation(from: database, using: backgroundContext)
		}
		
		self.fetchOperationQueue.waitUntilAllOperationsAreFinished()
		self.coreDataOperationQueue.waitUntilAllOperationsAreFinished()
		
		do {
			if self.isCancelled { return }
			try backgroundContext.save()
		} catch {
			errorBlock?(error)
		}
		
		NotificationCenter.default.post(name: .CloudCoreDidSyncFromCloud, object: nil)
	}
	
	public override func cancel() {
		self.fetchOperationQueue.cancelAllOperations()
		self.coreDataOperationQueue.cancelAllOperations()
		
		super.cancel()
	}
	
	private func addFetchDatabaseChangesOperation(from database: CKDatabase, using context: NSManagedObjectContext) {
		let databaseChangesOperation = FetchDatabaseChangesOperation(from: database, zoneName: CloudCore.config.zoneID.zoneName, tokens: tokens)
		
		databaseChangesOperation.fetchDatabaseChangesCompletionBlock = { recordZoneIDs, error in
			if let error = error {
				self.errorBlock?(error)
			} else {
				self.addRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, database: database, parentContext: context)
			}
		}
		
		fetchOperationQueue.addOperation(databaseChangesOperation)
	}
	
	private func addRecordZoneChangesOperation(recordZoneIDs: [CKRecordZoneID], database: CKDatabase, parentContext: NSManagedObjectContext) {
		if recordZoneIDs.isEmpty { return }
		
		let recordZoneChangesOperation = FetchRecordZoneChangesOperation(from: database, recordZoneIDs: recordZoneIDs, tokens: tokens)
		
		recordZoneChangesOperation.recordChangedBlock = {
			// Convert and write CKRecord To NSManagedObject Operation
			let convertOperation = RecordToCoreDataOperation(parentContext: parentContext, record: $0)
			convertOperation.errorBlock = { self.errorBlock?($0) }
			self.coreDataOperationQueue.addOperation(convertOperation)
		}
		
		recordZoneChangesOperation.recordWithIDWasDeletedBlock = {
			// Delete NSManagedObject with specified recordID Operation
			let deleteOperation = DeleteFromCoreDataOperation(parentContext: parentContext, recordID: $0)
			deleteOperation.errorBlock = { self.errorBlock?($0) }
			self.coreDataOperationQueue.addOperation(deleteOperation)
		}
		
		recordZoneChangesOperation.errorBlock = { self.errorBlock?($0) }
		
		fetchOperationQueue.addOperation(recordZoneChangesOperation)
	}

}
