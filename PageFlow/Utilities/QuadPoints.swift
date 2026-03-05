//
//  QuadPoints.swift
//  PageFlow
//
//  Shared utility for building PDF quadrilateral points from rectangles.
//

import AppKit

func buildQuadrilateralPoints(from rects: [CGRect], relativeTo union: CGRect) -> [NSValue] {
    rects.flatMap { rect -> [NSValue] in
        let tl = CGPoint(x: rect.minX - union.minX, y: rect.maxY - union.minY)
        let tr = CGPoint(x: rect.maxX - union.minX, y: rect.maxY - union.minY)
        let bl = CGPoint(x: rect.minX - union.minX, y: rect.minY - union.minY)
        let br = CGPoint(x: rect.maxX - union.minX, y: rect.minY - union.minY)
        return [tl, tr, bl, br].map(NSValue.init(point:))
    }
}
