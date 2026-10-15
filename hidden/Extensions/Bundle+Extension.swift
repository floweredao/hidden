//
//  Bundle+Extension.swift
//  Hidden Bar
//
//  Created by phucld on 12/19/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import Foundation

extension Bundle {
    var releaseVersionNumber: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var buildVersionNumber: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
    /// Fork display version, e.g. "1.11.1-fw.1". CFBundleShortVersionString must stay numeric.
    var forkVersionNumber: String? {
        return infoDictionary?["HBForkVersion"] as? String
    }
    /// Source commit stamped by the "Record Git Commit" build phase.
    var gitCommit: String? {
        return infoDictionary?["HBGitCommit"] as? String
    }
}
