//
//  Date+Extension.swift
//  Hidden Bar
//
//  Created by Trung Phan on 22/03/2021.
//  Copyright © 2021 Dwarves Foundation. All rights reserved.
//

import Foundation

extension Date {
    static func dateString() -> String {
        let dateFormater = DateFormatter()
        dateFormater.setLocalizedDateFormatFromTemplate("EEEddMMM")
        return dateFormater.string(from: Date())
    }
    static func timeString() -> String {
        let dateFormater = DateFormatter()
        dateFormater.timeStyle = .short
        return dateFormater.string(from: Date())
    }
}
