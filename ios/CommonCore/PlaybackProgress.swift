import Foundation

func progressRatio(_ position: Double, _ duration: Double) -> Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
