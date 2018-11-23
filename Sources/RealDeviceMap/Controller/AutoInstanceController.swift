//
//  AutoInstanceController.swift
//  RealDeviceMap
//
//  Created by Florian Kostenzer on 23.10.18.
//

import Foundation
import PerfectLib
import PerfectThread
import Turf
import S2Geometry

class AutoInstanceController: InstanceControllerProto {
        
    enum AutoType {
        case quest
    }
    
    public private(set) var name: String
    public private(set) var minLevel: UInt8
    public private(set) var maxLevel: UInt8
    public var delegate: InstanceControllerDelegate?

    private var multiPolygon: MultiPolygon
    private var type: AutoType
    private var stopsLock = Threading.Lock()
    private var allStops: [Pokestop]?
    private var todayStops: [Pokestop]?
    private var questClearerQueue: ThreadQueue?
    private var timezoneOffset: Int
    private var shouldExit = false
    private var bootstrappLock = Threading.Lock()
    private var bootstrappCellIDs = [S2CellId]()
    private var bootstrappTotalCount = 0
    
    private static let cooldownDataArray = [0.3: 0.16, 1: 1, 2: 2, 4: 3, 5: 4, 8: 5, 10: 7, 15: 9, 20: 12, 25: 15, 30: 17, 35: 18, 45: 20, 50: 20, 60: 21, 70: 23, 80: 24, 90: 25, 100: 26, 125: 29, 150: 32, 175: 34, 201: 37, 250: 41, 300: 46, 328: 48, 350: 50, 400: 54, 450: 58, 500: 62, 550: 66, 600: 70, 650: 74, 700: 77, 751: 82, 802: 84, 839: 88, 897: 90, 900: 91, 948: 95, 1007: 98, 1020: 102, 1100: 104, 1180: 109, 1200: 111, 1221: 113, 1300: 117, 1344: 119, Double(Int.max): 120].sorted { (lhs, rhs) -> Bool in
        lhs.key < rhs.key
    }
    
    init(name: String, multiPolygon: MultiPolygon, type: AutoType, timezoneOffset: Int, minLevel: UInt8, maxLevel: UInt8) {
        self.name = name
        self.minLevel = minLevel
        self.maxLevel = maxLevel
        self.type = type
        self.multiPolygon = multiPolygon
        self.timezoneOffset = timezoneOffset
        update()
        
        bootstrap()
        if type == .quest {
            questClearerQueue = Threading.getQueue(name: "\(name)-quest-clearer", type: .serial)
            questClearerQueue!.dispatch {
                
                while !self.shouldExit {
                    
                    let date = Date()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    formatter.timeZone = TimeZone(secondsFromGMT: timezoneOffset) ?? Localizer.global.timeZone
                    let formattedDate = formatter.string(from: date)
                    
                    let split = formattedDate.components(separatedBy: ":")
                    let hour = Int(split[0])!
                    let minute = Int(split[1])!
                    let second = Int(split[2])!
                    
                    let timeLeft = (23 - hour) * 3600 + (59 - minute) * 60 + (60 - second)
                    let at = date.addingTimeInterval(TimeInterval(timeLeft))
                    Log.debug(message: "[AutoInstanceController] [\(name)] Clearing Quests in \(timeLeft)s at \(formatter.string(from: at)) (Currently: \(formatter.string(from: date)))")
                    
                    if timeLeft > 0 {
                        Threading.sleep(seconds: Double(timeLeft))
                        if self.shouldExit {
                            return
                        }
                        
                        self.stopsLock.lock()
                        if self.allStops == nil {
                            Log.debug(message: "[AutoInstanceController] [\(name)] Tried clearing quests but no stops.")
                            self.stopsLock.unlock()
                            continue
                        }
                        
                        Log.debug(message: "[AutoInstanceController] [\(name)] Getting stop ids")
                        let ids = self.allStops!.map({ (stop) -> String in
                            return stop.id
                        })
                        var done = false
                        Log.debug(message: "[AutoInstanceController] [\(name)] Clearing Quests for ids: \(ids).")
                        while !done {
                            do {
                                try Pokestop.clearQuests(ids: ids)
                                done = true
                            } catch {
                                Threading.sleep(seconds: 5.0)
                                if self.shouldExit {
                                    self.stopsLock.unlock()
                                    return
                                }
                            }
                        }
                        self.stopsLock.unlock()
                        self.update()
                    }
                }
                
            }
        }
        
    }
    
    private func bootstrap() {
        Log.debug(message: "[AutoInstanceController] [\(name)] Checking Bootstrap Status...")
        let start = Date()
        var totalCount = 0
        var missingCellIDs = [S2CellId]()
        for polygon in multiPolygon.polygons {
            let cellIDs = polygon.getS2CellIDs(minLevel: 15, maxLevel: 15, maxCells: Int.max)
            totalCount += cellIDs.count
            let ids = cellIDs.map({ (id) -> UInt64 in
                return id.uid
            })
            var done = false
            var cells = [Cell]()
            while !done {
                do {
                    cells = try Cell.getInIDs(ids: ids)
                    done = true
                } catch {
                    Threading.sleep(seconds: 1)
                }
            }
            for cellID in cellIDs {
                if !cells.contains(where: { (cell) -> Bool in
                    return cell.id == cellID.uid
                }) {
                    missingCellIDs.append(cellID)
                }
            }
        }
        Log.debug(message: "[AutoInstanceController] [\(name)] Bootstrap Status: \(totalCount - missingCellIDs.count)/\(totalCount) after \(Date().timeIntervalSince(start).rounded(toStringWithDecimals: 2))s")
        bootstrappLock.lock()
        bootstrappCellIDs = missingCellIDs
        bootstrappTotalCount = totalCount
        bootstrappLock.unlock()
        
    }
    
    deinit {
        stop()
    }
    
    private func update() {
        switch type {
        case .quest:
            stopsLock.lock()
            self.allStops = [Pokestop]()
            for polygon in multiPolygon.polygons {
                
                if let bounds = BoundingBox(from: polygon.outerRing.coordinates),
                    let stops = try? Pokestop.getAll(minLat: bounds.southEast.latitude, maxLat: bounds.northWest.latitude, minLon: bounds.northWest.longitude, maxLon: bounds.southEast.longitude, updated: 0, questsOnly: false, showQuests: true) {
                    
                    for stop in stops {
                        let coord = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
                        if polygon.contains(coord, ignoreBoundary: false) {
                            self.allStops!.append(stop)
                        }
                    }
                }
                
            }
            self.todayStops = [Pokestop]()
            for stop in self.allStops! {
                if stop.questType == nil && stop.enabled == true {
                    self.todayStops!.append(stop)
                }
            }
            stopsLock.unlock()
            
        }
    }
    
    private func encounterCooldown(distM: Double) -> UInt32 {
        
        let dist = distM / 1000
        
        
        for data in AutoInstanceController.cooldownDataArray {
            if data.key >= dist {
                return UInt32(data.value * 60)
            }
        }
        return 0
    
    }
    
    func getTask(uuid: String, username: String?) -> [String : Any] {
        
        switch type {
        case .quest:
            
            bootstrappLock.lock()
            if !bootstrappCellIDs.isEmpty {
                
                if let target = bootstrappCellIDs.popLast() {
                    bootstrappLock.unlock()
                    let cell = S2Cell(cellId: target)
                    let center = S2LatLng(point: cell.center)
                    let coord = center.coord
                    let radians = 0.00007839251445558
                    
                    let centerNormalizedPoint = center.normalized.point
                    let circle = S2Cap(axis: centerNormalizedPoint, height: (radians*radians)/2)
                    let coverer = S2RegionCoverer()
                    coverer.maxCells = 100
                    coverer.maxLevel = 15
                    coverer.minLevel = 15
                    let cellIDs = coverer.getCovering(region: circle)
                    bootstrappLock.lock()
                    for cellID in cellIDs {
                        if let index = bootstrappCellIDs.index(of: cellID) {
                            bootstrappCellIDs.remove(at: index)
                        }
                    }
                    bootstrappLock.unlock()
                    
                    return ["action": "scan_raid", "lat": coord.latitude, "lon": coord.longitude]
                } else {
                    bootstrappLock.unlock()
                    return [String: Any]()
                }
                
            } else {
                bootstrappLock.unlock()
            
                guard let mysql = DBController.global.mysql else {
                    Log.error(message: "[InstanceControllerProto] Failed to connect to database.")
                    return [String : Any]()
                }
                
                stopsLock.lock()
                if todayStops == nil {
                    todayStops = [Pokestop]()
                }
                if allStops == nil {
                    allStops = [Pokestop]()
                }
                if allStops!.isEmpty {
                    stopsLock.unlock()
                    return [String: Any]()
                }
                if todayStops!.isEmpty {
                    let ids = self.allStops!.map({ (stop) -> String in
                        return stop.id
                    })
                    var newStops: [Pokestop]!
                    var done = false
                    while !done {
                        do {
                            newStops = try Pokestop.getIn(mysql: mysql, ids: ids)
                            done = true
                        } catch {
                            Threading.sleep(seconds: 1.0)
                        }
                    }
                    
                    for stop in newStops {
                        if stop.questType == nil && stop.enabled == true {
                            todayStops!.append(stop)
                        }
                    }
                    if todayStops!.isEmpty {
                        stopsLock.unlock()
                        delegate?.instanceControllerDone(name: name)
                        return [String : Any]()
                    }
                }
                stopsLock.unlock()
            
                var lastLat: Double?
                var lastLon: Double?
                var lastTime: UInt32?
                var account: Account?
                
                do {
                    if username != nil, let accountT = try Account.getWithUsername(mysql: mysql, username: username!) {
                        account = accountT
                        lastLat = accountT.lastEncounterLat
                        lastLon = accountT.lastEncounterLon
                        lastTime = accountT.lastEncounterTime
                    } else {
                        lastLat = Double(try DBController.global.getValueForKey(key: "AIC_\(uuid)_last_lat") ?? "")
                        lastLon = Double(try DBController.global.getValueForKey(key: "AIC_\(uuid)_last_lon") ?? "")
                        lastTime = UInt32(try DBController.global.getValueForKey(key: "AIC_\(uuid)_last_time") ?? "")
                    }
                } catch { }
                
                if username != nil && account != nil {
                    if account!.spins >= 500 {
                        return ["action": "switch_account", "min_level": minLevel, "max_level": maxLevel]
                    } else {
                        try? Account.spin(mysql: mysql, username: username!)
                    }
                }
                
                let newLon: Double
                let newLat: Double
                var encounterTime: UInt32
                
                if lastLat != nil && lastLon != nil {
                    
                    let current = CLLocationCoordinate2D(latitude: lastLat!, longitude: lastLon!)
                    
                    var closest: Pokestop!
                    var closestDistance: Double = 6378137
                    
                    stopsLock.lock()
                    let todayStopsC = todayStops
                    stopsLock.unlock()
                    if todayStopsC!.isEmpty {
                        return [String: Any]()
                    }
                    
                    for stop in todayStopsC! {
                        let coord = CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
                        let dist = current.distance(to: coord)
                        if dist < closestDistance {
                            closest = stop
                            closestDistance = dist
                        }
                    }
                    
                    newLon = closest.lon
                    newLat = closest.lat
                    let now = UInt32(Date().timeIntervalSince1970)
                    if lastTime == nil {
                        encounterTime = now
                    } else {
                        let encounterTimeT = lastTime! + encounterCooldown(distM: closestDistance)
                        if encounterTimeT < now {
                            encounterTime = now
                        } else {
                            encounterTime = encounterTimeT
                        }
                        
                        if encounterTime - now >= 7200 {
                            encounterTime = now + 7200
                        }
                    }
                    stopsLock.lock()
                    if let index = todayStops!.index(of: closest) {
                        todayStops!.remove(at: index)
                    }
                    stopsLock.unlock()
                } else {
                    stopsLock.lock()
                    if let stop = todayStops!.first {
                        newLon = stop.lon
                        newLat = stop.lat
                        encounterTime = UInt32(Date().timeIntervalSince1970)
                        _ = todayStops!.removeFirst()
                    } else {
                        stopsLock.unlock()
                        return [String: Any]()
                    }
                    stopsLock.unlock()
                }
                
                if username != nil && account != nil {
                    try? Account.didEncounter(mysql: mysql, username: username!, lon: newLon, lat: newLat, time: encounterTime)
                } else {
                    try? DBController.global.setValueForKey(key: "AIC_\(uuid)_last_lat", value: newLat.description)
                    try? DBController.global.setValueForKey(key: "AIC_\(uuid)_last_lon", value: newLon.description)
                    try? DBController.global.setValueForKey(key: "AIC_\(uuid)_last_time", value: encounterTime.description)
                }
                
                let delayT = Int(Date(timeIntervalSince1970: Double(encounterTime)).timeIntervalSinceNow)
                let delay: Int
                if delayT < 0 {
                    delay = 0
                } else {
                    delay = delayT + 1
                }
                
                stopsLock.lock()
                if todayStops!.isEmpty {
                    let ids = self.allStops!.map({ (stop) -> String in
                        return stop.id
                    })
                    stopsLock.unlock()
                    var newStops: [Pokestop]!
                    var done = false
                    while !done {
                        do {
                            newStops = try Pokestop.getIn(mysql: mysql, ids: ids)
                            done = true
                        } catch {
                            Threading.sleep(seconds: 1.0)
                        }
                    }
                    
                    stopsLock.lock()
                    for stop in newStops {
                        if stop.questType == nil && stop.enabled == true {
                            todayStops!.append(stop)
                        }
                    }
                    if todayStops!.isEmpty {
                        Log.info(message: "[AutoInstanceController] [\(name)] Instance done")
                        delegate?.instanceControllerDone(name: name)
                    }
                    stopsLock.unlock()
                } else {
                    stopsLock.unlock()
                }
                
                return ["action": "scan_quest", "lat": newLat, "lon": newLon, "delay": delay, "min_level": minLevel, "max_level": maxLevel]
            }
        }

    }
    
    func getStatus() -> String {
        switch type {
        case .quest:
            bootstrappLock.lock()
            if !bootstrappCellIDs.isEmpty {
                let totalCount = bootstrappTotalCount
                let count = totalCount - bootstrappCellIDs.count
                bootstrappLock.unlock()
                
                let percentage: Double
                if totalCount > 0 {
                    percentage = Double(count) / Double(totalCount) * 100
                } else {
                    percentage = 100
                }
                return "Bootstrapping \(count)/\(totalCount) (\(percentage.rounded(toStringWithDecimals: 1))%)"
            } else {
                bootstrappLock.unlock()
                stopsLock.lock()
                var currentCountDb = 0
                let ids = self.allStops!.map({ (stop) -> String in
                    return stop.id
                })
                stopsLock.unlock()
                
                if let stops = try? Pokestop.getIn(ids: ids) {
                    for stop in stops {
                        if stop.questType != nil {
                            currentCountDb += 1
                        }
                    }
                }
                
                stopsLock.lock()
                let maxCount = self.allStops?.count ?? 0
                let currentCount = maxCount - (self.todayStops?.count ?? 0)
                stopsLock.unlock()
                
                let percentage: Double
                if maxCount > 0 {
                    percentage = Double(currentCount) / Double(maxCount) * 100
                } else {
                    percentage = 100
                }
                let percentageReal: Double
                if maxCount > 0 {
                    percentageReal = Double(currentCountDb) / Double(maxCount) * 100
                } else {
                    percentageReal = 100
                }
                return "Done: \(currentCountDb)|\(currentCount)/\(maxCount) (\(percentageReal.rounded(toStringWithDecimals: 1))|\(percentage.rounded(toStringWithDecimals: 1))%)"
            }
        }
    }
    
    func reload() {
        update()
    }
    
    func stop() {
        self.shouldExit = true
        if questClearerQueue != nil {
            Threading.destroyQueue(questClearerQueue!)
        }
    }
}
