// Created by Cal Stephens on 12/14/21.
// Copyright © 2021 Airbnb Inc. All rights reserved.

import QuartzCore

// MARK: - ShapeLayer

/// The CALayer type responsible for rendering `ShapeLayerModel`s
final class ShapeLayer: BaseCompositionLayer {

  // MARK: Lifecycle

  init(shapeLayer: ShapeLayerModel, context: LayerContext) throws {
    self.shapeLayer = shapeLayer
    super.init(layerModel: shapeLayer)
    try setUpGroups(context: context)
  }

  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Called by CoreAnimation to create a shadow copy of this layer
  /// More details: https://developer.apple.com/documentation/quartzcore/calayer/1410842-init
  override init(layer: Any) {
    guard let typedLayer = layer as? Self else {
      fatalError("\(Self.self).init(layer:) incorrectly called with \(type(of: layer))")
    }

    shapeLayer = typedLayer.shapeLayer
    super.init(layer: typedLayer)
  }

  // MARK: Private

  private let shapeLayer: ShapeLayerModel

  private func setUpGroups(context: LayerContext) throws {
    // If the layer has a `Repeater`, the `Group`s are duplicated and offset
    // based on the copy count of the repeater.
    if let repeater = shapeLayer.items.first(where: { $0 is Repeater }) as? Repeater {
      try setUpRepeater(repeater, context: context)
    } else {
      try setupGroups(from: shapeLayer.items, parentGroup: nil, parentGroupPath: [], context: context)
    }
  }

  private func setUpRepeater(_ repeater: Repeater, context: LayerContext) throws {
    let items = shapeLayer.items.filter { !($0 is Repeater) }
    let copyCount = Int(try repeater.copies.exactlyOneKeyframe(context: context, description: "repeater copies").value)

    for index in 0..<copyCount {
      for groupLayer in try makeGroupLayers(from: items, parentGroup: nil, parentGroupPath: [], context: context) {
        let repeatedLayer = RepeaterLayer(repeater: repeater, childLayer: groupLayer, index: index)
        addSublayer(repeatedLayer)
      }
    }
  }

}

// MARK: - GroupLayer

/// The CALayer type responsible for rendering `Group`s
final class GroupLayer: BaseAnimationLayer {

  // MARK: Lifecycle

  init(group: Group, items: [ShapeItemLayer.Item], groupPath: [String], context: LayerContext) throws {
    self.group = group
    self.items = items
    self.groupPath = groupPath
    super.init()
    try setupLayerHierarchy(context: context)
  }

  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Called by CoreAnimation to create a shadow copy of this layer
  /// More details: https://developer.apple.com/documentation/quartzcore/calayer/1410842-init
  override init(layer: Any) {
    guard let typedLayer = layer as? Self else {
      fatalError("\(Self.self).init(layer:) incorrectly called with \(type(of: layer))")
    }

    group = typedLayer.group
    items = typedLayer.items
    groupPath = typedLayer.groupPath
    super.init(layer: typedLayer)
  }

  // MARK: Internal

  override func setupAnimations(context: LayerAnimationContext) throws {
    try super.setupAnimations(context: context)

    if let (shapeTransform, context) = nonGroupItems.first(ShapeTransform.self, context: context) {
      try addTransformAnimations(for: shapeTransform, context: context)
      try addOpacityAnimation(for: shapeTransform, context: context)
    }
  }

  // MARK: Private

  private let group: Group

  /// `ShapeItemLayer.Item`s rendered by this `Group`
  ///  - In the original `ShapeLayer` data model, these items could have originated from a different group
  private let items: [ShapeItemLayer.Item]

  /// The keypath that represents this group, with respect to the parent `ShapeLayer`
  ///  - Due to the way `GroupLayer`s are setup, the original `ShapeItem`
  ///    hierarchy from the `ShapeLayer` data model may no longer exactly
  ///    match the hierarchy of `GroupLayer` / `ShapeItemLayer`s constructed
  ///    at runtime. Since animation keypaths need to match the original
  ///    structure of the `ShapeLayer` data model, we track that info here.
  private let groupPath: [String]

  /// `ShapeItem`s (other than nested `Group`s) that are rendered by this layer
  private lazy var nonGroupItems = items.filter { !($0.item is Group) }

  private func setupLayerHierarchy(context: LayerContext) throws {
    // Groups can contain other groups, so we may have to continue
    // recursively creating more `GroupLayer`s
    try setupGroups(from: group.items, parentGroup: group, parentGroupPath: groupPath, context: context)

    // Create `ShapeItemLayer`s for each subgroup of shapes that should be rendered as a single unit
    //  - These groups are listed from front-to-back, so we have to add the sublayers in reverse order
    for shapeRenderGroup in nonGroupItems.shapeRenderGroups.validGroups.reversed() {
      // When there are multiple path-drawing items, they're supposed to be rendered
      // in a single `CAShapeLayer` (instead of rendering them in separate layers) so
      // `CAShapeLayerFillRule.evenOdd` can be applied correctly if the paths overlap.
      // Since a `CAShapeLayer` only supports animating a single `CGPath` from a single `KeyframeGroup<BezierPath>`,
      // this requires combining all of the path-drawing items into a single set of keyframes.
      if
        shapeRenderGroup.pathItems.count > 1,
        // We currently only support this codepath for `Shape` items that directly contain bezier path keyframes.
        // We could also support this for other path types like rectangles, ellipses, and polygons with more work.
        shapeRenderGroup.pathItems.allSatisfy({ $0.item is Shape }),
        // `Trim`s are currently only applied correctly using individual `ShapeItemLayer`s,
        // because each path has to be trimmed separately.
        !shapeRenderGroup.otherItems.contains(where: { $0.item is Trim })
      {
        let allPathKeyframes = shapeRenderGroup.pathItems.compactMap { ($0.item as? Shape)?.path }
        let combinedShape = CombinedShapeItem(
          shapes: Keyframes.combined(allPathKeyframes),
          name: group.name)

        let sublayer = try ShapeItemLayer(
          shape: ShapeItemLayer.Item(item: combinedShape, groupPath: shapeRenderGroup.pathItems[0].groupPath),
          otherItems: shapeRenderGroup.otherItems,
          context: context)

        addSublayer(sublayer)
      }

      // Otherwise, if each `ShapeItem` that draws a `GGPath` animates independently,
      // we have to create a separate `ShapeItemLayer` for each one. This may render
      // incorrectly if there are multiple paths that overlap with each other.
      else {
        for pathDrawingItem in shapeRenderGroup.pathItems {
          let sublayer = try ShapeItemLayer(
            shape: pathDrawingItem,
            otherItems: shapeRenderGroup.otherItems,
            context: context)

          addSublayer(sublayer)
        }
      }
    }
  }

}

extension CALayer {
  /// Sets up `GroupLayer`s for each `Group` in the given list of `ShapeItem`s
  ///  - Each `Group` item becomes its own `GroupLayer` sublayer.
  ///  - Other `ShapeItem` are applied to all sublayers
  fileprivate func setupGroups(
    from items: [ShapeItem],
    parentGroup: Group?,
    parentGroupPath: [String],
    context: LayerContext)
    throws
  {
    let groupLayers = try makeGroupLayers(
      from: items,
      parentGroup: parentGroup,
      parentGroupPath: parentGroupPath,
      context: context)

    for groupLayer in groupLayers {
      addSublayer(groupLayer)
    }
  }

  /// Creates a `GroupLayer` for each `Group` in the given list of `ShapeItem`s
  ///  - Each `Group` item becomes its own `GroupLayer` sublayer.
  ///  - Other `ShapeItem` are applied to all sublayers
  fileprivate func makeGroupLayers(
    from items: [ShapeItem],
    parentGroup: Group?,
    parentGroupPath: [String],
    context: LayerContext)
    throws -> [GroupLayer]
  {
    var (groupItems, otherItems) = items
      .filter { !$0.hidden }
      .grouped(by: { $0 is Group })

    // Handle the top-level `shapeLayer.items` array. This is typically just a single `Group`,
    // but in practice can be any combination of items. The implementation expects all path-drawing
    // shape items to be managed by a `GroupLayer`, so if there's a top-level path item we
    // have to create a placeholder group.
    if parentGroup == nil, otherItems.contains(where: { $0.drawsCGPath }) {
      groupItems = [Group(items: items, name: "")]
      otherItems = []
    }

    // Any child items that wouldn't be included in a valid shape render group
    // need to be applied to child groups (otherwise they'd be silently ignored).
    let inheritedItemsForChildGroups = otherItems
      .map { ShapeItemLayer.Item(item: $0, groupPath: parentGroupPath) }
      .shapeRenderGroups
      .unusedItems

    // Groups are listed from front to back,
    // but `CALayer.sublayers` are listed from back to front.
    let groupsInZAxisOrder = groupItems.reversed()

    return try groupsInZAxisOrder.compactMap { group in
      guard let group = group as? Group else { return nil }

      var pathForChildren = parentGroupPath
      if !group.name.isEmpty {
        pathForChildren.append(group.name)
      }

      let childItems = group.items
        .filter { !$0.hidden }
        .map { ShapeItemLayer.Item(item: $0, groupPath: pathForChildren) }

      // Some shape item properties are affected by scaling (e.g. stroke width).
      // The child group may have a `ShapeTransform` that affects the scale of its items,
      // but shouldn't affect the scale of any inherited items. To prevent this scale
      // from affecting inherited items, we have to apply an inverse scale to them.
      let inheritedItems = try inheritedItemsForChildGroups.map { item in
        ShapeItemLayer.Item(
          item: try item.item.scaledCopyForChildGroup(group, context: context),
          groupPath: item.groupPath)
      }

      return try GroupLayer(
        group: group,
        items: childItems + inheritedItems,
        groupPath: pathForChildren,
        context: context)
    }
  }
}

extension ShapeItem {
  /// Whether or not this `ShapeItem` is responsible for rendering a `CGPath`
  var drawsCGPath: Bool {
    switch type {
    case .ellipse, .rectangle, .shape, .star:
      return true

    case .fill, .gradientFill, .group, .gradientStroke, .merge,
         .repeater, .round, .stroke, .trim, .transform, .unknown:
      return false
    }
  }

  /// Whether or not this `ShapeItem` provides a fill for a set of shapes
  var isFill: Bool {
    switch type {
    case .fill, .gradientFill:
      return true

    case .ellipse, .rectangle, .shape, .star, .group, .gradientStroke,
         .merge, .repeater, .round, .stroke, .trim, .transform, .unknown:
      return false
    }
  }

  /// Whether or not this `ShapeItem` provides a stroke for a set of shapes
  var isStroke: Bool {
    switch type {
    case .stroke, .gradientStroke:
      return true

    case .ellipse, .rectangle, .shape, .star, .group, .gradientFill,
         .merge, .repeater, .round, .fill, .trim, .transform, .unknown:
      return false
    }
  }

  // For any inherited shape items that are affected by scaling (e.g. strokes but not fills),
  // any `ShapeTransform` in the given child group isn't supposed to be applied to the item.
  // To cancel out the effect of the transform, we can apply an inverse transform to the
  // shape item.
  func scaledCopyForChildGroup(_ childGroup: Group, context: LayerContext) throws -> ShapeItem {
    guard
      // Path-drawing items aren't inherited by child groups in this way
      !drawsCGPath,
      // Stroke widths are affected by scaling, but fill colors aren't.
      // We can expand this to other types of items in the future if necessary.
      let stroke = self as? StrokeShapeItem,
      // We only need to handle scaling if there's a `ShapeTransform` present
      let transform = childGroup.items.first(where: { $0 is ShapeTransform }) as? ShapeTransform
    else { return self }

    let newWidth = try Keyframes.combined(stroke.width, transform.scale) { strokeWidth, scale -> LottieVector1D in
      // Since we're applying this scale to a scalar value rather than to a layer,
      // we can only handle cases where the scale is also a scalar (e.g. the same for both x and y)
      try context.compatibilityAssert(scale.x == scale.y, """
        The Core Animation rendering engine doesn't support applying separate x/y scale values \
        (x: \(scale.x), y: \(scale.y)) to this stroke item (\(self.name)).
        """)

      return LottieVector1D(strokeWidth.value * (100 / scale.x))
    }

    return stroke.copy(width: newWidth)
  }
}

extension Collection {
  /// Splits this collection into two groups, based on the given predicate
  func grouped(by predicate: (Element) -> Bool) -> (trueElements: [Element], falseElements: [Element]) {
    var trueElements = [Element]()
    var falseElements = [Element]()

    for element in self {
      if predicate(element) {
        trueElements.append(element)
      } else {
        falseElements.append(element)
      }
    }

    return (trueElements, falseElements)
  }
}

// MARK: - ShapeRenderGroup

/// A group of `ShapeItem`s that should be rendered together as a single unit
struct ShapeRenderGroup {
  /// The items in this group that render `CGPath`s.
  /// Valid shape render groups must have at least one path-drawing item.
  var pathItems: [ShapeItemLayer.Item] = []
  /// Shape items that modify the appearance of the shapes rendered by this group
  var otherItems: [ShapeItemLayer.Item] = []
}

extension Array where Element == ShapeItemLayer.Item {
  /// Splits this list of `ShapeItem`s into groups that should be rendered together as individual units,
  /// plus the remaining items that were not included in any group.
  var shapeRenderGroups: (validGroups: [ShapeRenderGroup], unusedItems: [ShapeItemLayer.Item]) {
    var renderGroups = [ShapeRenderGroup()]

    for item in self {
      // `renderGroups` is non-empty, so is guaranteed to have a valid end index
      let lastIndex = renderGroups.indices.last!

      if item.item.drawsCGPath {
        renderGroups[lastIndex].pathItems.append(item)
      }

      // `Fill` items are unique, because they specifically only apply to _previous_ shapes in a `Group`
      //  - For example, with [Rectangle, Fill(Red), Circle, Fill(Blue)], the Rectangle should be Red
      //    but the Circle should be Blue.
      //  - To handle this, we create a new `ShapeRenderGroup` when we encounter a `Fill` item
      else if item.item.isFill {
        renderGroups[lastIndex].otherItems.append(item)
        renderGroups.append(ShapeRenderGroup())
      }

      // Other items in the list are applied to all subgroups
      else {
        for index in renderGroups.indices {
          renderGroups[index].otherItems.append(item)
        }
      }
    }

    // `Fill` and `Stroke` items have an `alpha` property that can be animated separately,
    // but each layer only has a single `opacity` property, so we have to create
    // separate layers / render groups for each of these if necessary.
    renderGroups = renderGroups.flatMap { group -> [ShapeRenderGroup] in
      let (strokesAndFills, otherItems) = group.otherItems.grouped(by: { $0.item.isFill || $0.item.isStroke })

      // However, if all of the strokes / fills have the exact same opacity animation configuration,
      // then we can continue using a single layer / render group.
      let allAlphaAnimationsAreIdentical = strokesAndFills.allSatisfy { item in
        (item.item as? OpacityAnimationModel)?.opacity
          == (strokesAndFills.first?.item as? OpacityAnimationModel)?.opacity
      }

      if allAlphaAnimationsAreIdentical {
        return [group]
      }

      // Create a new group for each stroke / fill
      return strokesAndFills.map { strokeOrFill in
        ShapeRenderGroup(
          pathItems: group.pathItems,
          otherItems: [strokeOrFill] + otherItems)
      }
    }

    var unusedItems = [ShapeItemLayer.Item]()
    for index in renderGroups.indices.reversed() {
      let renderGroup = renderGroups[index]

      // All valid render groups must have a path, otherwise the items wouldn't be rendered
      if renderGroup.pathItems.isEmpty {
        unusedItems.append(contentsOf: renderGroup.otherItems)
        renderGroups.remove(at: index)
      }
    }

    return (validGroups: renderGroups, unusedItems: unusedItems)
  }
}
