// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/field_promotability.dart';
import 'package:_fe_analyzer_shared/src/macros/executor.dart' as macro;
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart' as file_state;
import 'package:analyzer/src/dart/analysis/file_state.dart' hide DirectiveUri;
import 'package:analyzer/src/dart/analysis/info_declaration_store.dart';
import 'package:analyzer/src/dart/analysis/unlinked_data.dart';
import 'package:analyzer/src/dart/ast/ast.dart' as ast;
import 'package:analyzer/src/dart/ast/mixin_super_invoked_names.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/field_name_non_promotability_info.dart'
    as element_model;
import 'package:analyzer/src/dart/resolver/scope.dart';
import 'package:analyzer/src/summary2/combinator.dart';
import 'package:analyzer/src/summary2/constructor_initializer_resolver.dart';
import 'package:analyzer/src/summary2/default_value_resolver.dart';
import 'package:analyzer/src/summary2/element_builder.dart';
import 'package:analyzer/src/summary2/export.dart';
import 'package:analyzer/src/summary2/informative_data.dart';
import 'package:analyzer/src/summary2/link.dart';
import 'package:analyzer/src/summary2/macro_application.dart';
import 'package:analyzer/src/summary2/macro_merge.dart';
import 'package:analyzer/src/summary2/metadata_resolver.dart';
import 'package:analyzer/src/summary2/reference.dart';
import 'package:analyzer/src/summary2/reference_resolver.dart';
import 'package:analyzer/src/summary2/types_builder.dart';
import 'package:analyzer/src/util/performance/operation_performance.dart';
import 'package:analyzer/src/utilities/extensions/collection.dart';

class AugmentedClassDeclarationBuilder
    extends AugmentedInstanceDeclarationBuilder {
  final ClassElementImpl declaration;

  AugmentedClassDeclarationBuilder({
    required this.declaration,
  }) {
    addFields(declaration.fields);
    addConstructors(declaration.constructors);
    addAccessors(declaration.accessors);
    addMethods(declaration.methods);
  }

  void augment(ClassElementImpl element) {
    addFields(element.fields);
    addConstructors(element.constructors);
    addAccessors(element.accessors);
    addMethods(element.methods);
  }
}

abstract class AugmentedInstanceDeclarationBuilder {
  final Map<String, FieldElementImpl> fields = {};
  final Map<String, ConstructorElementImpl> constructors = {};
  final Map<String, PropertyAccessorElementImpl> accessors = {};
  final Map<String, MethodElementImpl> methods = {};

  void addAccessors(List<PropertyAccessorElementImpl> elements) {
    for (final element in elements) {
      final name = element.name;
      if (element.isAugmentation) {
        final existing = accessors[name];
        if (existing != null) {
          existing.augmentation = element;
          element.augmentationTarget = existing;
          element.variable = existing.variable;
        }
      }
      accessors[name] = element;
    }
  }

  void addConstructors(List<ConstructorElementImpl> elements) {
    for (final element in elements) {
      final name = element.name;
      if (element.isAugmentation) {
        final existing = constructors[name];
        if (existing != null) {
          existing.augmentation = element;
          element.augmentationTarget = existing;
        }
      }
      constructors[name] = element;
    }
  }

  void addFields(List<FieldElementImpl> elements) {
    for (final element in elements) {
      final name = element.name;
      if (element.isAugmentation) {
        final existing = fields[name];
        if (existing != null) {
          existing.augmentation = element;
          element.augmentationTarget = existing;
        }
      }
      fields[name] = element;
    }
  }

  void addMethods(List<MethodElementImpl> elements) {
    for (final element in elements) {
      final name = element.name;
      if (element.isAugmentation) {
        final existing = methods[name];
        if (existing != null) {
          existing.augmentation = element;
          element.augmentationTarget = existing;
        }
      }
      methods[name] = element;
    }
  }
}

class AugmentedMixinDeclarationBuilder
    extends AugmentedInstanceDeclarationBuilder {
  final MixinElementImpl declaration;

  AugmentedMixinDeclarationBuilder({
    required this.declaration,
  }) {
    addFields(declaration.fields);
    addAccessors(declaration.accessors);
    addMethods(declaration.methods);
  }

  void augment(MixinElementImpl element) {
    addFields(element.fields);
    addAccessors(element.accessors);
    addMethods(element.methods);
  }
}

class DefiningLinkingUnit extends LinkingUnit {
  DefiningLinkingUnit({
    required super.reference,
    required super.node,
    required super.element,
    required super.container,
  });
}

class ImplicitEnumNodes {
  final EnumElementImpl element;
  final ast.NamedTypeImpl valuesTypeNode;
  final ConstFieldElementImpl valuesField;

  ImplicitEnumNodes({
    required this.element,
    required this.valuesTypeNode,
    required this.valuesField,
  });
}

class LibraryBuilder {
  final Linker linker;
  final LibraryFileKind kind;
  final Uri uri;
  final Reference reference;
  final LibraryElementImpl element;
  final List<LinkingUnit> units;

  final List<ImplicitEnumNodes> implicitEnumNodes = [];

  /// The top-level elements that can be augmented.
  final Map<String, AugmentedInstanceDeclarationBuilder> _augmentedBuilders =
      {};

  /// The top-level elements that can be augmented.
  final Map<String, ElementImpl> _augmentationTargets = {};

  /// Local declarations.
  final Map<String, Reference> _declaredReferences = {};

  /// The export scope of the library.
  ExportScope exportScope = ExportScope();

  /// The `export` directives that export this library.
  final List<Export> exports = [];

  final List<List<macro.MacroExecutionResult>> _macroResults = [];

  LibraryBuilder._({
    required this.linker,
    required this.kind,
    required this.uri,
    required this.reference,
    required this.element,
    required this.units,
  });

  void addExporters() {
    final containers = [element, ...element.augmentations];
    for (var containerIndex = 0;
        containerIndex < containers.length;
        containerIndex++) {
      final container = containers[containerIndex];
      final exportElements = container.libraryExports;
      for (var exportIndex = 0;
          exportIndex < exportElements.length;
          exportIndex++) {
        final exportElement = exportElements[exportIndex];

        final exportedLibrary = exportElement.exportedLibrary;
        if (exportedLibrary is! LibraryElementImpl) {
          continue;
        }

        final combinators = exportElement.combinators.map((combinator) {
          if (combinator is ShowElementCombinator) {
            return Combinator.show(combinator.shownNames);
          } else if (combinator is HideElementCombinator) {
            return Combinator.hide(combinator.hiddenNames);
          } else {
            throw UnimplementedError();
          }
        }).toList();

        final exportedUri = exportedLibrary.source.uri;
        final exportedBuilder = linker.builders[exportedUri];

        final export = Export(
          exporter: this,
          location: ExportLocation(
            containerIndex: containerIndex,
            exportIndex: exportIndex,
          ),
          combinators: combinators,
        );
        if (exportedBuilder != null) {
          exportedBuilder.exports.add(export);
        } else {
          final exportedReferences = exportedLibrary.exportedReferences;
          for (final exported in exportedReferences) {
            final reference = exported.reference;
            final name = reference.name;
            if (reference.isSetter) {
              export.addToExportScope('$name=', exported);
            } else {
              export.addToExportScope(name, exported);
            }
          }
        }
      }
    }
  }

  void buildClassSyntheticConstructors() {
    bool hasConstructor(ClassElementImpl element) {
      if (element.constructors.isNotEmpty) return true;
      if (element.augmentation case final augmentation?) {
        return hasConstructor(augmentation);
      }
      return false;
    }

    for (final classElement in element.topLevelElements) {
      if (classElement is! ClassElementImpl) continue;
      if (classElement.isMixinApplication) continue;
      if (classElement.isAugmentation) continue;
      if (hasConstructor(classElement)) continue;

      final constructor = ConstructorElementImpl('', -1)..isSynthetic = true;
      final containerRef = classElement.reference!.getChild('@constructor');
      final reference = containerRef.getChild('new');
      reference.element = constructor;
      constructor.reference = reference;

      classElement.constructors = [constructor].toFixedList();

      if (classElement.augmented case AugmentedClassElementImpl augmented) {
        augmented.constructors = classElement.constructors;
      }
    }
  }

  /// Build elements for declarations in the library units, add top-level
  /// declarations to the local scope, for combining into export scopes.
  void buildElements() {
    _buildDirectives(
      kind: kind,
      container: element,
    );

    for (var linkingUnit in units) {
      var elementBuilder = ElementBuilder(
        libraryBuilder: this,
        container: linkingUnit.container,
        unitReference: linkingUnit.reference,
        unitElement: linkingUnit.element,
      );
      if (linkingUnit is DefiningLinkingUnit) {
        elementBuilder.buildLibraryElementChildren(linkingUnit.node);
      }
      elementBuilder.buildDeclarationElements(linkingUnit.node);
    }
    _declareDartCoreDynamicNever();
  }

  void buildEnumChildren() {
    var typeProvider = element.typeProvider;
    for (var enum_ in implicitEnumNodes) {
      enum_.element.supertype =
          typeProvider.enumType ?? typeProvider.objectType;
      var valuesType = typeProvider.listType(
        element.typeSystem.instantiateInterfaceToBounds(
          element: enum_.element,
          nullabilitySuffix: typeProvider.objectType.nullabilitySuffix,
        ),
      );
      enum_.valuesTypeNode.type = valuesType;
      enum_.valuesField.type = valuesType;
    }
  }

  void buildInitialExportScope() {
    exportScope = ExportScope();
    _declaredReferences.forEach((name, reference) {
      if (name.startsWith('_')) return;
      if (reference.isPrefix) return;
      exportScope.declare(name, reference);
    });
  }

  void collectMixinSuperInvokedNames() {
    for (var linkingUnit in units) {
      for (var declaration in linkingUnit.node.declarations) {
        if (declaration is ast.MixinDeclarationImpl) {
          var names = <String>{};
          var collector = MixinSuperInvokedNamesCollector(names);
          for (var executable in declaration.members) {
            if (executable is ast.MethodDeclarationImpl) {
              executable.body.accept(collector);
            }
          }
          var element = declaration.declaredElement as MixinElementImpl;
          element.superInvokedNames = names.toList();
        }
      }
    }
  }

  /// Computes which fields in this library are promotable.
  void computeFieldPromotability() {
    _FieldPromotability(this,
            enabled: element.featureSet.isEnabled(Feature.inference_update_2))
        .perform();
  }

  void declare(String name, Reference reference) {
    _declaredReferences[name] = reference;
  }

  /// Completes with `true` if a macro application was run in this library.
  ///
  /// Completes with `false` if there are no macro applications to run, either
  /// because we ran all, or those that we have not run yet have dependencies
  /// of interfaces declared in other libraries that, and we have not run yet
  /// declarations phase macro applications for them.
  Future<MacroDeclarationsPhaseStepResult> executeMacroDeclarationsPhase({
    required ElementImpl? targetElement,
  }) async {
    final macroApplier = linker.macroApplier;
    if (macroApplier == null) {
      return MacroDeclarationsPhaseStepResult.nothing;
    }

    final results = await macroApplier.executeDeclarationsPhase(
      library: element,
      targetElement: targetElement,
    );

    // No more applications to execute.
    if (results == null) {
      return MacroDeclarationsPhaseStepResult.nothing;
    }

    await _addMacroResults(macroApplier, results, buildTypes: true);

    // Check if a new top-level declaration was added.
    final augmentationUnit = units.last.element;
    if (augmentationUnit.functions.isNotEmpty ||
        augmentationUnit.topLevelVariables.isNotEmpty) {
      element.resetScope();
      return MacroDeclarationsPhaseStepResult.topDeclaration;
    }

    // Probably class member declarations.
    return MacroDeclarationsPhaseStepResult.otherProgress;
  }

  Future<void> executeMacroDefinitionsPhase({
    required OperationPerformanceImpl performance,
  }) async {
    final macroApplier = linker.macroApplier;
    if (macroApplier == null) {
      return;
    }

    while (true) {
      final results = await macroApplier.executeDefinitionsPhase();

      // No more applications to execute.
      if (results == null) {
        return;
      }

      await _addMacroResults(macroApplier, results, buildTypes: true);
    }
  }

  Future<void> executeMacroTypesPhase({
    required OperationPerformanceImpl performance,
  }) async {
    final macroApplier = linker.macroApplier;
    if (macroApplier == null) {
      return;
    }

    while (true) {
      final results = await macroApplier.executeTypesPhase();

      // No more applications to execute.
      if (results == null) {
        break;
      }

      await _addMacroResults(macroApplier, results, buildTypes: false);
    }
  }

  /// Fills with macro applications in user code.
  Future<void> fillMacroApplier(LibraryMacroApplier macroApplier) async {
    for (final linkingUnit in units) {
      await macroApplier.add(
        libraryElement: element,
        container: element,
        unit: linkingUnit.node,
      );
    }
  }

  AugmentedInstanceDeclarationBuilder? getAugmentedBuilder(String name) {
    return _augmentedBuilders[name];
  }

  /// Merges accumulated [_macroResults] and corresponding macro augmentation
  /// libraries into a single macro augmentation library.
  Future<void> mergeMacroAugmentations({
    required OperationPerformanceImpl performance,
  }) async {
    final macroApplier = linker.macroApplier;
    if (macroApplier == null) {
      return;
    }

    final augmentationCode = macroApplier.buildAugmentationLibraryCode(
      _macroResults.flattenedToList2,
    );
    if (augmentationCode == null) {
      return;
    }

    kind.disposeMacroAugmentations();

    // Remove import for partial macro augmentations.
    element.augmentationImports = element.augmentationImports
        .take(element.augmentationImports.length - _macroResults.length)
        .toFixedList();

    // Remove units with partial macro augmentations.
    final partialUnits = units.sublist(units.length - _macroResults.length);
    units.length -= _macroResults.length;

    final importState = kind.addMacroAugmentation(
      augmentationCode,
      addLibraryAugmentDirective: true,
      partialIndex: null,
    );
    final importedAugmentation = importState.importedAugmentation!;
    final importedFile = importedAugmentation.file;

    final unitNode = importedFile.parse();
    final unitElement = CompilationUnitElementImpl(
      source: importedFile.source,
      librarySource: importedFile.source,
      lineInfo: unitNode.lineInfo,
    );
    unitElement.setCodeRange(0, unitNode.length);

    final unitReference =
        reference.getChild('@augmentation').getChild(importedFile.uriStr);
    _bindReference(unitReference, unitElement);

    final augmentation = LibraryAugmentationElementImpl(
      augmentationTarget: element,
      nameOffset: importedAugmentation.unlinked.libraryKeywordOffset,
    );
    augmentation.definingCompilationUnit = unitElement;
    augmentation.reference = unitReference;

    final informativeBytes = importedFile.unlinked2.informativeBytes;
    augmentation.macroGenerated = MacroGeneratedAugmentationLibrary(
      code: importedFile.content,
      informativeBytes: informativeBytes,
    );

    _buildDirectives(
      kind: importedAugmentation,
      container: augmentation,
    );

    MacroElementsMerger(
      partialUnits: partialUnits,
      unitReference: unitReference,
      unitNode: unitNode,
      unitElement: unitElement,
      augmentation: augmentation,
    ).perform();

    // Set offsets the same way as when reading from summary.
    InformativeDataApplier(
      linker.elementFactory,
      {},
      NoOpInfoDeclarationStore(),
    ).applyToUnit(unitElement, informativeBytes);

    final importUri = DirectiveUriWithAugmentationImpl(
      relativeUriString: importState.uri.relativeUriStr,
      relativeUri: importState.uri.relativeUri,
      source: importedFile.source,
      augmentation: augmentation,
    );

    final import = AugmentationImportElementImpl(
      importKeywordOffset: importState.unlinked.importKeywordOffset,
      uri: importUri,
    );
    import.isSynthetic = true;

    element.augmentationImports = [
      ...element.augmentationImports,
      import,
    ].toFixedList();
  }

  void putAugmentedBuilder(
    String name,
    AugmentedInstanceDeclarationBuilder element,
  ) {
    _augmentedBuilders[name] = element;
  }

  void resolveConstructorFieldFormals() {
    for (final class_ in element.topLevelElements) {
      if (class_ is! ClassElementImpl) continue;
      if (class_.isMixinApplication) continue;

      final augmented = class_.augmented;
      if (augmented == null) continue;

      for (final constructor in class_.constructors) {
        for (final parameter in constructor.parameters) {
          if (parameter is FieldFormalParameterElementImpl) {
            parameter.field = augmented.getField(parameter.name);
          }
        }
      }
    }
  }

  void resolveConstructors() {
    ConstructorInitializerResolver(linker, this).resolve();
  }

  void resolveDefaultValues() {
    DefaultValueResolver(linker, this).resolve();
  }

  void resolveMetadata() {
    for (var linkingUnit in units) {
      var resolver = MetadataResolver(linker, linkingUnit.element, this);
      linkingUnit.node.accept(resolver);
    }
  }

  void resolveTypes(NodesToBuildType nodesToBuildType) {
    for (var linkingUnit in units) {
      var resolver = ReferenceResolver(
        linker,
        nodesToBuildType,
        linkingUnit.container,
      );
      linkingUnit.node.accept(resolver);
    }
  }

  void setDefaultSupertypes() {
    var shouldResetClassHierarchies = false;
    final objectType = element.typeProvider.objectType;
    for (final interface in element.topLevelElements) {
      switch (interface) {
        case ClassElementImpl():
          if (interface.isAugmentation) continue;
          if (interface.isDartCoreObject) continue;
          if (interface.supertype == null) {
            shouldResetClassHierarchies = true;
            interface.supertype = objectType;
          }
        case MixinElementImpl():
          if (interface.isAugmentation) continue;
          final augmented = interface.augmented!;
          if (augmented.superclassConstraints.isEmpty) {
            shouldResetClassHierarchies = true;
            interface.superclassConstraints = [objectType];
            if (augmented is AugmentedMixinElementImpl) {
              augmented.superclassConstraints = [objectType];
            }
          }
      }
    }
    if (shouldResetClassHierarchies) {
      element.session.classHierarchy.removeOfLibraries({uri});
    }
  }

  void storeExportScope() {
    element.exportedReferences = exportScope.toReferences();

    var definedNames = <String, Element>{};
    for (var entry in exportScope.map.entries) {
      var reference = entry.value.reference;
      var element = linker.elementFactory.elementOfReference(reference);
      if (element != null) {
        definedNames[entry.key] = element;
      }
    }

    var namespace = Namespace(definedNames);
    element.exportNamespace = namespace;

    var entryPoint = namespace.get(FunctionElement.MAIN_FUNCTION_NAME);
    if (entryPoint is FunctionElement) {
      element.entryPoint = entryPoint;
    }
  }

  void updateAugmentationTarget<T extends ElementImpl>(
    String name,
    T augmentation,
    void Function(T target) update,
  ) {
    final target = _augmentationTargets[name];
    if (target is T) {
      update(target);
    }
    _augmentationTargets[name] = augmentation;
  }

  LibraryAugmentationElementImpl _addMacroAugmentation(
    AugmentationImportWithFile state,
  ) {
    final import = _buildAugmentationImport(element, state);
    import.isSynthetic = true;
    element.augmentationImports = [
      ...element.augmentationImports,
      import,
    ].toFixedList();

    final augmentation = import.importedAugmentation!;
    augmentation.macroGenerated = MacroGeneratedAugmentationLibrary(
      code: state.importedFile.content,
      informativeBytes: state.importedFile.unlinked2.informativeBytes,
    );

    return augmentation;
  }

  /// Add results from the declarations or definitions phase.
  Future<void> _addMacroResults(
    LibraryMacroApplier macroApplier,
    List<macro.MacroExecutionResult> results, {
    required bool buildTypes,
  }) async {
    // No results from the application.
    if (results.isEmpty) {
      return;
    }

    _macroResults.add(results);

    final augmentationCode = macroApplier.buildAugmentationLibraryCode(
      results,
    );
    if (augmentationCode == null) {
      return;
    }

    final importState = kind.addMacroAugmentation(
      augmentationCode,
      addLibraryAugmentDirective: true,
      partialIndex: _macroResults.length,
    );

    final augmentation = _addMacroAugmentation(importState);

    final macroLinkingUnit = units.last;
    ElementBuilder(
      libraryBuilder: this,
      container: macroLinkingUnit.container,
      unitReference: macroLinkingUnit.reference,
      unitElement: macroLinkingUnit.element,
    ).buildDeclarationElements(macroLinkingUnit.node);

    if (buildTypes) {
      final nodesToBuildType = NodesToBuildType();
      final resolver =
          ReferenceResolver(linker, nodesToBuildType, augmentation);
      macroLinkingUnit.node.accept(resolver);
      TypesBuilder(linker).build(nodesToBuildType);
    }

    // Append applications from the partial augmentation.
    await macroApplier.add(
      libraryElement: element,
      container: augmentation,
      unit: macroLinkingUnit.node,
    );
  }

  AugmentationImportElementImpl _buildAugmentationImport(
    LibraryOrAugmentationElementImpl augmentationTarget,
    AugmentationImportState state,
  ) {
    final DirectiveUri uri;
    if (state is AugmentationImportWithFile) {
      final importedAugmentation = state.importedAugmentation;
      if (importedAugmentation != null) {
        final importedFile = importedAugmentation.file;

        final unitNode = importedFile.parse();
        final unitElement = CompilationUnitElementImpl(
          source: importedFile.source,
          // TODO(scheglov): Remove this parameter.
          librarySource: importedFile.source,
          lineInfo: unitNode.lineInfo,
        );
        unitNode.declaredElement = unitElement;
        unitElement.setCodeRange(0, unitNode.length);

        final unitReference =
            reference.getChild('@augmentation').getChild(importedFile.uriStr);
        _bindReference(unitReference, unitElement);

        final augmentation = LibraryAugmentationElementImpl(
          augmentationTarget: augmentationTarget,
          nameOffset: importedAugmentation.unlinked.libraryKeywordOffset,
        );
        augmentation.definingCompilationUnit = unitElement;
        augmentation.reference = unitElement.reference!;

        units.add(
          DefiningLinkingUnit(
            reference: unitReference,
            node: unitNode,
            element: unitElement,
            container: augmentation,
          ),
        );

        _buildDirectives(
          kind: importedAugmentation,
          container: augmentation,
        );

        uri = DirectiveUriWithAugmentationImpl(
          relativeUriString: state.uri.relativeUriStr,
          relativeUri: state.uri.relativeUri,
          source: importedFile.source,
          augmentation: augmentation,
        );
      } else {
        uri = DirectiveUriWithSourceImpl(
          relativeUriString: state.uri.relativeUriStr,
          relativeUri: state.uri.relativeUri,
          source: state.importedSource,
        );
      }
    } else {
      final selectedUri = state.uri;
      if (selectedUri is file_state.DirectiveUriWithUri) {
        uri = DirectiveUriWithRelativeUriImpl(
          relativeUriString: selectedUri.relativeUriStr,
          relativeUri: selectedUri.relativeUri,
        );
      } else if (selectedUri is file_state.DirectiveUriWithString) {
        uri = DirectiveUriWithRelativeUriStringImpl(
          relativeUriString: selectedUri.relativeUriStr,
        );
      } else {
        uri = DirectiveUriImpl();
      }
    }

    return AugmentationImportElementImpl(
      importKeywordOffset: state.unlinked.importKeywordOffset,
      uri: uri,
    );
  }

  List<NamespaceCombinator> _buildCombinators(
    List<UnlinkedCombinator> combinators2,
  ) {
    return combinators2.map((unlinked) {
      if (unlinked.isShow) {
        return ShowElementCombinatorImpl()
          ..offset = unlinked.keywordOffset
          ..end = unlinked.endOffset
          ..shownNames = unlinked.names;
      } else {
        return HideElementCombinatorImpl()
          ..offset = unlinked.keywordOffset
          ..end = unlinked.endOffset
          ..hiddenNames = unlinked.names;
      }
    }).toFixedList();
  }

  /// Builds directive elements, for the library and recursively for its
  /// augmentations.
  void _buildDirectives({
    required LibraryOrAugmentationFileKind kind,
    required LibraryOrAugmentationElementImpl container,
  }) {
    container.libraryExports = kind.libraryExports.map((state) {
      return _buildExport(state);
    }).toFixedList();

    container.libraryImports = kind.libraryImports.map((state) {
      return _buildImport(
        container: container,
        state: state,
      );
    }).toFixedList();

    container.augmentationImports = kind.augmentationImports.map((state) {
      return _buildAugmentationImport(container, state);
    }).toFixedList();
  }

  LibraryExportElementImpl _buildExport(LibraryExportState state) {
    final combinators = _buildCombinators(
      state.unlinked.combinators,
    );

    final DirectiveUri uri;
    if (state is LibraryExportWithFile) {
      final exportedLibraryKind = state.exportedLibrary;
      if (exportedLibraryKind != null) {
        final exportedFile = exportedLibraryKind.file;
        final exportedUri = exportedFile.uri;
        final elementFactory = linker.elementFactory;
        final exportedLibrary = elementFactory.libraryOfUri2(exportedUri);
        uri = DirectiveUriWithLibraryImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: exportedLibrary.source,
          library: exportedLibrary,
        );
      } else {
        uri = DirectiveUriWithSourceImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: state.exportedSource,
        );
      }
    } else if (state is LibraryExportWithInSummarySource) {
      final exportedLibrarySource = state.exportedLibrarySource;
      if (exportedLibrarySource != null) {
        final exportedUri = exportedLibrarySource.uri;
        final elementFactory = linker.elementFactory;
        final exportedLibrary = elementFactory.libraryOfUri2(exportedUri);
        uri = DirectiveUriWithLibraryImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: exportedLibrary.source,
          library: exportedLibrary,
        );
      } else {
        uri = DirectiveUriWithSourceImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: state.exportedSource,
        );
      }
    } else {
      final selectedUri = state.selectedUri;
      if (selectedUri is file_state.DirectiveUriWithUri) {
        uri = DirectiveUriWithRelativeUriImpl(
          relativeUriString: selectedUri.relativeUriStr,
          relativeUri: selectedUri.relativeUri,
        );
      } else if (selectedUri is file_state.DirectiveUriWithString) {
        uri = DirectiveUriWithRelativeUriStringImpl(
          relativeUriString: selectedUri.relativeUriStr,
        );
      } else {
        uri = DirectiveUriImpl();
      }
    }

    return LibraryExportElementImpl(
      combinators: combinators,
      exportKeywordOffset: state.unlinked.exportKeywordOffset,
      uri: uri,
    );
  }

  LibraryImportElementImpl _buildImport({
    required LibraryOrAugmentationElementImpl container,
    required LibraryImportState state,
  }) {
    final importPrefix = state.unlinked.prefix.mapOrNull((unlinked) {
      final prefix = _buildPrefix(
        name: unlinked.name,
        nameOffset: unlinked.nameOffset,
        container: container,
      );
      if (unlinked.deferredOffset != null) {
        return DeferredImportElementPrefixImpl(
          element: prefix,
        );
      } else {
        return ImportElementPrefixImpl(
          element: prefix,
        );
      }
    });

    final combinators = _buildCombinators(
      state.unlinked.combinators,
    );

    final DirectiveUri uri;
    if (state is LibraryImportWithFile) {
      final importedLibraryKind = state.importedLibrary;
      if (importedLibraryKind != null) {
        final importedFile = importedLibraryKind.file;
        final importedUri = importedFile.uri;
        final elementFactory = linker.elementFactory;
        final importedLibrary = elementFactory.libraryOfUri2(importedUri);
        uri = DirectiveUriWithLibraryImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: importedLibrary.source,
          library: importedLibrary,
        );
      } else {
        uri = DirectiveUriWithSourceImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: state.importedSource,
        );
      }
    } else if (state is LibraryImportWithInSummarySource) {
      final importedLibrarySource = state.importedLibrarySource;
      if (importedLibrarySource != null) {
        final importedUri = importedLibrarySource.uri;
        final elementFactory = linker.elementFactory;
        final importedLibrary = elementFactory.libraryOfUri2(importedUri);
        uri = DirectiveUriWithLibraryImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: importedLibrary.source,
          library: importedLibrary,
        );
      } else {
        uri = DirectiveUriWithSourceImpl(
          relativeUriString: state.selectedUri.relativeUriStr,
          relativeUri: state.selectedUri.relativeUri,
          source: state.importedSource,
        );
      }
    } else {
      final selectedUri = state.selectedUri;
      if (selectedUri is file_state.DirectiveUriWithUri) {
        uri = DirectiveUriWithRelativeUriImpl(
          relativeUriString: selectedUri.relativeUriStr,
          relativeUri: selectedUri.relativeUri,
        );
      } else if (selectedUri is file_state.DirectiveUriWithString) {
        uri = DirectiveUriWithRelativeUriStringImpl(
          relativeUriString: selectedUri.relativeUriStr,
        );
      } else {
        uri = DirectiveUriImpl();
      }
    }

    return LibraryImportElementImpl(
      combinators: combinators,
      importKeywordOffset: state.unlinked.importKeywordOffset,
      prefix: importPrefix,
      uri: uri,
    )..isSynthetic = state.isSyntheticDartCore;
  }

  PrefixElementImpl _buildPrefix({
    required String name,
    required int nameOffset,
    required LibraryOrAugmentationElementImpl container,
  }) {
    // TODO(scheglov): Make reference required.
    final containerRef = container.reference!;
    final reference = containerRef.getChild('@prefix').getChild(name);
    final existing = reference.element;
    if (existing is PrefixElementImpl) {
      return existing;
    } else {
      final result = PrefixElementImpl(
        name,
        nameOffset,
        reference: reference,
      );
      container.encloseElement(result);
      return result;
    }
  }

  /// These elements are implicitly declared in `dart:core`.
  void _declareDartCoreDynamicNever() {
    if (reference.name == 'dart:core') {
      var dynamicRef = reference.getChild('dynamic');
      dynamicRef.element = DynamicElementImpl.instance;
      declare('dynamic', dynamicRef);

      var neverRef = reference.getChild('Never');
      neverRef.element = NeverElementImpl.instance;
      declare('Never', neverRef);
    }
  }

  static void build(Linker linker, LibraryFileKind inputLibrary) {
    final elementFactory = linker.elementFactory;
    final rootReference = linker.rootReference;

    final libraryFile = inputLibrary.file;
    final libraryUriStr = libraryFile.uriStr;
    final libraryReference = rootReference.getChild(libraryUriStr);

    final libraryUnitNode = libraryFile.parse();

    var name = '';
    var nameOffset = -1;
    var nameLength = 0;
    for (final directive in libraryUnitNode.directives) {
      if (directive is ast.LibraryDirectiveImpl) {
        final nameIdentifier = directive.name2;
        if (nameIdentifier != null) {
          name = nameIdentifier.components.map((e) => e.name).join('.');
          nameOffset = nameIdentifier.offset;
          nameLength = nameIdentifier.length;
        }
        break;
      }
    }

    final libraryElement = LibraryElementImpl(
      elementFactory.analysisContext,
      elementFactory.analysisSession,
      name,
      nameOffset,
      nameLength,
      libraryUnitNode.featureSet,
    );
    libraryElement.isSynthetic = !libraryFile.exists;
    libraryElement.languageVersion = libraryUnitNode.languageVersion!;
    _bindReference(libraryReference, libraryElement);
    elementFactory.setLibraryTypeSystem(libraryElement);

    final unitContainerRef = libraryReference.getChild('@unit');

    final linkingUnits = <LinkingUnit>[];
    {
      final unitElement = CompilationUnitElementImpl(
        source: libraryFile.source,
        librarySource: libraryFile.source,
        lineInfo: libraryUnitNode.lineInfo,
      );
      libraryUnitNode.declaredElement = unitElement;
      unitElement.isSynthetic = !libraryFile.exists;
      unitElement.setCodeRange(0, libraryUnitNode.length);

      final unitReference = unitContainerRef.getChild(libraryFile.uriStr);
      _bindReference(unitReference, unitElement);

      linkingUnits.add(
        DefiningLinkingUnit(
          reference: unitReference,
          node: libraryUnitNode,
          element: unitElement,
          container: libraryElement,
        ),
      );

      libraryElement.definingCompilationUnit = unitElement;
    }

    libraryElement.parts = inputLibrary.parts.map((partState) {
      final uriState = partState.uri;
      final DirectiveUri directiveUri;
      if (partState is PartWithFile) {
        final includedPart = partState.includedPart;
        if (includedPart != null) {
          final partFile = includedPart.file;
          final partUnitNode = partFile.parse();
          final unitElement = CompilationUnitElementImpl(
            source: partFile.source,
            librarySource: libraryFile.source,
            lineInfo: partUnitNode.lineInfo,
          );
          partUnitNode.declaredElement = unitElement;
          unitElement.isSynthetic = !partFile.exists;
          unitElement.uri = partFile.uriStr;
          unitElement.setCodeRange(0, partUnitNode.length);

          final unitReference = unitContainerRef.getChild(partFile.uriStr);
          _bindReference(unitReference, unitElement);

          linkingUnits.add(
            LinkingUnit(
              reference: unitReference,
              node: partUnitNode,
              container: libraryElement,
              element: unitElement,
            ),
          );

          directiveUri = DirectiveUriWithUnitImpl(
            relativeUriString: partState.uri.relativeUriStr,
            relativeUri: partState.uri.relativeUri,
            unit: unitElement,
          );
        } else {
          directiveUri = DirectiveUriWithSourceImpl(
            relativeUriString: partState.uri.relativeUriStr,
            relativeUri: partState.uri.relativeUri,
            source: partState.includedFile.source,
          );
        }
      } else if (uriState is file_state.DirectiveUriWithSource) {
        directiveUri = DirectiveUriWithSourceImpl(
          relativeUriString: uriState.relativeUriStr,
          relativeUri: uriState.relativeUri,
          source: uriState.source,
        );
      } else if (uriState is file_state.DirectiveUriWithUri) {
        directiveUri = DirectiveUriWithRelativeUriImpl(
          relativeUriString: uriState.relativeUriStr,
          relativeUri: uriState.relativeUri,
        );
      } else if (uriState is file_state.DirectiveUriWithString) {
        directiveUri = DirectiveUriWithRelativeUriStringImpl(
          relativeUriString: uriState.relativeUriStr,
        );
      } else {
        directiveUri = DirectiveUriImpl();
      }
      return directiveUri;
    }).map((directiveUri) {
      return PartElementImpl(
        uri: directiveUri,
      );
    }).toFixedList();

    final builder = LibraryBuilder._(
      linker: linker,
      kind: inputLibrary,
      uri: libraryFile.uri,
      reference: libraryReference,
      element: libraryElement,
      units: linkingUnits,
    );

    linker.builders[builder.uri] = builder;
  }

  static void _bindReference(Reference reference, ElementImpl element) {
    reference.element = element;
    element.reference = reference;
  }
}

class LinkingUnit {
  final Reference reference;
  final ast.CompilationUnitImpl node;
  final LibraryOrAugmentationElementImpl container;
  final CompilationUnitElementImpl element;

  LinkingUnit({
    required this.reference,
    required this.node,
    required this.container,
    required this.element,
  });
}

enum MacroDeclarationsPhaseStepResult {
  nothing,
  otherProgress,
  topDeclaration,
}

/// This class examines all the [InterfaceElement]s in a library and determines
/// which fields are promotable within that library.
class _FieldPromotability extends FieldPromotability<InterfaceElement,
    FieldElement, PropertyAccessorElement> {
  /// The [_libraryBuilder] for the library being analyzed.
  final LibraryBuilder _libraryBuilder;

  final bool enabled;

  /// Fields that might be promotable, if not marked unpromotable later.
  final List<FieldElementImpl> _potentiallyPromotableFields = [];

  _FieldPromotability(this._libraryBuilder, {required this.enabled});

  @override
  Iterable<InterfaceElement> getSuperclasses(InterfaceElement class_,
      {required bool ignoreImplements}) {
    List<InterfaceElement> result = [];
    var supertype = class_.supertype;
    if (supertype != null) {
      result.add(supertype.element);
    }
    for (var m in class_.mixins) {
      result.add(m.element);
    }
    if (!ignoreImplements) {
      for (var interface in class_.interfaces) {
        result.add(interface.element);
      }
      if (class_ is MixinElement) {
        for (var constraint in class_.superclassConstraints) {
          result.add(constraint.element);
        }
      }
    }
    return result;
  }

  /// Computes which fields are promotable and updates their `isPromotable`
  /// properties accordingly.
  void perform() {
    // Iterate through all the classes, enums, and mixins in the library,
    // recording the non-synthetic instance fields and getters of each.
    for (var unitElement in _libraryBuilder.element.units) {
      for (var class_ in unitElement.classes) {
        _handleMembers(addClass(class_, isAbstract: class_.isAbstract), class_);
      }
      for (var enum_ in unitElement.enums) {
        _handleMembers(addClass(enum_, isAbstract: false), enum_);
      }
      for (var mixin_ in unitElement.mixins) {
        _handleMembers(addClass(mixin_, isAbstract: true), mixin_);
      }
      // Private representation fields of extension types are always promotable.
      // They also don't affect promotability of any other fields.
      for (final extensionType in unitElement.extensionTypes) {
        final representation = extensionType.representation;
        if (representation.name.startsWith('_')) {
          representation.isPromotable = true;
        }
      }
    }

    // Compute the set of field names that are not promotable.
    var fieldNonPromotabilityInfo = computeNonPromotabilityInfo();

    // Set the `isPromotable` bit for each field element that *is* promotable.
    for (var field in _potentiallyPromotableFields) {
      if (fieldNonPromotabilityInfo[field.name] == null) {
        field.isPromotable = true;
      }
    }

    _libraryBuilder.element.fieldNameNonPromotabilityInfo = {
      for (var MapEntry(:key, :value) in fieldNonPromotabilityInfo.entries)
        key: element_model.FieldNameNonPromotabilityInfo(
            conflictingFields: value.conflictingFields,
            conflictingGetters: value.conflictingGetters,
            conflictingNsmClasses: value.conflictingNsmClasses)
    };
  }

  /// Records all the non-synthetic instance fields and getters of [class_] into
  /// [classInfo].
  void _handleMembers(
      ClassInfo<InterfaceElement> classInfo, InterfaceElementImpl class_) {
    for (var field in class_.fields) {
      if (field.isStatic || field.isSynthetic) {
        continue;
      }

      var nonPromotabilityReason = addField(classInfo, field, field.name,
          isFinal: field.isFinal,
          isAbstract: field.isAbstract,
          isExternal: field.isExternal);
      if (enabled && nonPromotabilityReason == null) {
        _potentiallyPromotableFields.add(field);
      }
    }

    for (var accessor in class_.accessors) {
      if (!accessor.isGetter || accessor.isStatic || accessor.isSynthetic) {
        continue;
      }

      var nonPromotabilityReason = addGetter(classInfo, accessor, accessor.name,
          isAbstract: accessor.isAbstract);
      if (enabled && nonPromotabilityReason == null) {
        _potentiallyPromotableFields.add(accessor.variable as FieldElementImpl);
      }
    }
  }
}

extension<T> on T? {
  R? mapOrNull<R>(R Function(T) mapper) {
    final self = this;
    return self != null ? mapper(self) : null;
  }
}
