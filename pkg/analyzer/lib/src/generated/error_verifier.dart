// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:_fe_analyzer_shared/src/flow_analysis/flow_analysis.dart';
import 'package:_fe_analyzer_shared/src/macros/api.dart' as macro;
import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/ast/extensions.dart';
import 'package:analyzer/src/dart/element/class_hierarchy.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/inheritance_manager3.dart';
import 'package:analyzer/src/dart/element/non_covariant_type_parameter_position.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/element/well_bounded.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';
import 'package:analyzer/src/dart/resolver/scope.dart';
import 'package:analyzer/src/dart/resolver/variance.dart';
import 'package:analyzer/src/diagnostic/diagnostic.dart';
import 'package:analyzer/src/diagnostic/diagnostic_factory.dart';
import 'package:analyzer/src/error/codes.dart';
import 'package:analyzer/src/error/constructor_fields_verifier.dart';
import 'package:analyzer/src/error/correct_override.dart';
import 'package:analyzer/src/error/duplicate_definition_verifier.dart';
import 'package:analyzer/src/error/getter_setter_types_verifier.dart';
import 'package:analyzer/src/error/literal_element_verifier.dart';
import 'package:analyzer/src/error/required_parameters_verifier.dart';
import 'package:analyzer/src/error/return_type_verifier.dart';
import 'package:analyzer/src/error/super_formal_parameters_verifier.dart';
import 'package:analyzer/src/error/type_arguments_verifier.dart';
import 'package:analyzer/src/error/use_result_verifier.dart';
import 'package:analyzer/src/generated/element_resolver.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error_detection_helpers.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/generated/parser.dart' show ParserErrorCode;
import 'package:analyzer/src/generated/this_access_tracker.dart';
import 'package:analyzer/src/summary2/macro_application_error.dart';
import 'package:analyzer/src/utilities/extensions/object.dart';
import 'package:analyzer/src/utilities/extensions/string.dart';

class EnclosingExecutableContext {
  final ExecutableElement? element;
  final bool isAsynchronous;
  final bool isConstConstructor;
  final bool isGenerativeConstructor;
  final bool isGenerator;
  final bool inFactoryConstructor;
  final bool inStaticMethod;

  /// If this [EnclosingExecutableContext] is the first argument in a method
  /// invocation of [Future.catchError], returns the return type expected for
  /// `Future<T>.catchError`'s `onError` parameter, which is `FutureOr<T>`,
  /// otherwise `null`.
  final InterfaceType? catchErrorOnErrorReturnType;

  /// The return statements that have a value.
  final List<ReturnStatement> _returnsWith = [];

  /// The return statements that do not have a value.
  final List<ReturnStatement> _returnsWithout = [];

  /// This flag is set to `false` when the declared return type is not legal
  /// for the kind of the function body, e.g. not `Future` for `async`.
  bool hasLegalReturnType = true;

  /// The number of enclosing [CatchClause] in this executable.
  int catchClauseLevel = 0;

  EnclosingExecutableContext(this.element,
      {bool? isAsynchronous, this.catchErrorOnErrorReturnType})
      : isAsynchronous =
            isAsynchronous ?? (element != null && element.isAsynchronous),
        isConstConstructor = element is ConstructorElement && element.isConst,
        isGenerativeConstructor =
            element is ConstructorElement && !element.isFactory,
        isGenerator = element != null && element.isGenerator,
        inFactoryConstructor = _inFactoryConstructor(element),
        inStaticMethod = _inStaticMethod(element);

  EnclosingExecutableContext.empty() : this(null);

  String? get displayName {
    return element?.displayName;
  }

  bool get isClosure {
    return element is FunctionElement && element!.displayName.isEmpty;
  }

  bool get isConstructor => element is ConstructorElement;

  bool get isFunction {
    if (element is FunctionElement) {
      return element!.displayName.isNotEmpty;
    }
    return element is PropertyAccessorElement;
  }

  bool get isMethod => element is MethodElement;

  bool get isSynchronous => !isAsynchronous;

  DartType get returnType {
    return catchErrorOnErrorReturnType ?? element!.returnType;
  }

  static bool _inFactoryConstructor(Element? element) {
    var enclosing = element?.enclosingElement;
    if (enclosing == null) {
      return false;
    }
    if (element is ConstructorElement) {
      return element.isFactory;
    }
    return _inFactoryConstructor(enclosing);
  }

  static bool _inStaticMethod(Element? element) {
    var enclosing = element?.enclosingElement;
    if (enclosing == null) {
      return false;
    }
    if (enclosing is InterfaceElement || enclosing is ExtensionElement) {
      if (element is ExecutableElement) {
        return element.isStatic;
      }
    }
    return _inStaticMethod(enclosing);
  }
}

/// A visitor used to traverse an AST structure looking for additional errors
/// and warnings not covered by the parser and resolver.
class ErrorVerifier extends RecursiveAstVisitor<void>
    with ErrorDetectionHelpers {
  /// The error reporter by which errors will be reported.
  @override
  final ErrorReporter errorReporter;

  /// The current library that is being analyzed.
  final LibraryElementImpl _currentLibrary;

  /// The type representing the type 'int'.
  late final InterfaceType _intType;

  /// The options for verification.
  final AnalysisOptionsImpl options;

  /// The object providing access to the types defined by the language.
  final TypeProvider _typeProvider;

  /// The type system primitives
  @override
  late final TypeSystemImpl typeSystem;

  /// The manager for the inheritance mappings.
  final InheritanceManager3 _inheritanceManager;

  /// A flag indicating whether the visitor is currently within a comment.
  bool _isInComment = false;

  /// The stack of flags, where `true` at the top (last) of the stack indicates
  /// that the visitor is in the initializer of a lazy local variable. When the
  /// top is `false`, we might be not in a local variable, or it is not `lazy`,
  /// etc.
  final List<bool> _isInLateLocalVariable = [false];

  /// A flag indicating whether the visitor is currently within a native class
  /// declaration.
  bool _isInNativeClass = false;

  /// A flag indicating whether the visitor is currently within a static
  /// variable declaration.
  bool _isInStaticVariableDeclaration = false;

  /// A flag indicating whether the visitor is currently within an instance
  /// variable declaration, which is not `late`.
  bool _isInInstanceNotLateVariableDeclaration = false;

  /// A flag indicating whether the visitor is currently within a constructor
  /// initializer.
  bool _isInConstructorInitializer = false;

  /// This is set to `true` iff the visitor is currently within a function typed
  /// formal parameter.
  bool _isInFunctionTypedFormalParameter = false;

  /// A flag indicating whether the visitor is currently within code in the SDK.
  bool _isInSystemLibrary = false;

  /// The class containing the AST nodes being visited, or `null` if we are not
  /// in the scope of a class.
  InterfaceElement? _enclosingClass;

  /// The element of the extension being visited, or `null` if we are not
  /// in the scope of an extension.
  ExtensionElement? _enclosingExtension;

  /// The helper for tracking if the current location has access to `this`.
  final ThisAccessTracker _thisAccessTracker = ThisAccessTracker.unit();

  /// The context of the method or function that we are currently visiting, or
  /// `null` if we are not inside a method or function.
  EnclosingExecutableContext _enclosingExecutable =
      EnclosingExecutableContext.empty();

  /// A table mapping names to the exported elements.
  final Map<String, Element> _exportedElements = HashMap<String, Element>();

  /// A set of the names of the variable initializers we are visiting now.
  final HashSet<String> _namesForReferenceToDeclaredVariableInInitializer =
      HashSet<String>();

  /// The elements that will be defined later in the current scope, but right
  /// now are not declared.
  HiddenElements? _hiddenElements;

  final _UninstantiatedBoundChecker _uninstantiatedBoundChecker;

  /// The features enabled in the unit currently being checked for errors.
  FeatureSet? _featureSet;

  final LibraryVerificationContext libraryVerificationContext;
  final RequiredParametersVerifier _requiredParametersVerifier;
  final DuplicateDefinitionVerifier _duplicateDefinitionVerifier;
  final UseResultVerifier _checkUseVerifier;
  late final TypeArgumentsVerifier _typeArgumentsVerifier;
  late final ConstructorFieldsVerifier _constructorFieldsVerifier;
  late final ReturnTypeVerifier _returnTypeVerifier;
  final TypeSystemOperations typeSystemOperations;

  /// Initialize a newly created error verifier.
  ErrorVerifier(this.errorReporter, this._currentLibrary, this._typeProvider,
      this._inheritanceManager, this.libraryVerificationContext, this.options,
      {required this.typeSystemOperations})
      : _uninstantiatedBoundChecker =
            _UninstantiatedBoundChecker(errorReporter),
        _checkUseVerifier = UseResultVerifier(errorReporter),
        _requiredParametersVerifier = RequiredParametersVerifier(errorReporter,
            strictCasts: options.strictCasts),
        _duplicateDefinitionVerifier = DuplicateDefinitionVerifier(
          _inheritanceManager,
          _currentLibrary,
          errorReporter,
          libraryVerificationContext.duplicationDefinitionContext,
        ) {
    _isInSystemLibrary = _currentLibrary.source.uri.isScheme('dart');
    _isInStaticVariableDeclaration = false;
    _isInConstructorInitializer = false;
    _intType = _typeProvider.intType;
    typeSystem = _currentLibrary.typeSystem;
    _typeArgumentsVerifier =
        TypeArgumentsVerifier(options, _currentLibrary, errorReporter);
    _constructorFieldsVerifier = ConstructorFieldsVerifier(
      typeSystem: typeSystem,
      errorReporter: errorReporter,
    );
    _returnTypeVerifier = ReturnTypeVerifier(
      typeProvider: _typeProvider as TypeProviderImpl,
      typeSystem: typeSystem,
      errorReporter: errorReporter,
      strictCasts: strictCasts,
    );
  }

  InterfaceElement? get enclosingClass => _enclosingClass;

  /// For consumers of error verification as a library, (currently just the
  /// angular plugin), expose a setter that can make the errors reported more
  /// accurate when dangling code snippets are being resolved from a class
  /// context. Note that this setter is very defensive for potential misuse; it
  /// should not be modified in the middle of visiting a tree and requires an
  /// analyzer-provided Impl instance to work.
  set enclosingClass(InterfaceElement? interfaceElement) {
    assert(_enclosingClass == null);
    assert(_enclosingExecutable.element == null);
  }

  @override
  bool get strictCasts => options.strictCasts;

  /// The language team is thinking about adding abstract fields, or external
  /// fields. But for now we will ignore such fields in `Struct` subtypes.
  bool get _isEnclosingClassFfiStruct {
    var superClass = _enclosingClass?.supertype?.element;
    return superClass != null &&
        _isDartFfiLibrary(superClass.library) &&
        superClass.name == 'Struct';
  }

  /// The language team is thinking about adding abstract fields, or external
  /// fields. But for now we will ignore such fields in `Struct` subtypes.
  bool get _isEnclosingClassFfiUnion {
    var superClass = _enclosingClass?.supertype?.element;
    return superClass != null &&
        _isDartFfiLibrary(superClass.library) &&
        superClass.name == 'Union';
  }

  bool get _isNonNullableByDefault =>
      _featureSet?.isEnabled(Feature.non_nullable) ?? false;

  @override
  List<DiagnosticMessage> computeWhyNotPromotedMessages(
      SyntacticEntity errorEntity,
      Map<DartType, NonPromotionReason>? whyNotPromoted) {
    return [];
  }

  @override
  void visitAnnotation(Annotation node) {
    _checkForInvalidAnnotationFromDeferredLibrary(node);
    _requiredParametersVerifier.visitAnnotation(node);
    super.visitAnnotation(node);
  }

  @override
  void visitAsExpression(AsExpression node) {
    _checkForTypeAnnotationDeferredClass(node.type);
    super.visitAsExpression(node);
  }

  @override
  void visitAssertInitializer(AssertInitializer node) {
    _isInConstructorInitializer = true;
    try {
      super.visitAssertInitializer(node);
    } finally {
      _isInConstructorInitializer = false;
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    TokenType operatorType = node.operator.type;
    Expression lhs = node.leftHandSide;
    if (operatorType == TokenType.QUESTION_QUESTION_EQ) {
      _checkForDeadNullCoalesce(node.readType as TypeImpl, node.rightHandSide);
    }
    _checkForAssignmentToFinal(lhs);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    if (!_enclosingExecutable.isAsynchronous) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.AWAIT_IN_WRONG_CONTEXT, node.awaitKeyword);
    }
    if (_isNonNullableByDefault) {
      checkForUseOfVoidResult(node.expression);
    }

    _checkForAwaitInLateLocalVariableInitializer(node);
    _checkForAwaitOfExtensionTypeNotFuture(node);
    super.visitAwaitExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    Token operator = node.operator;
    TokenType type = operator.type;
    if (type == TokenType.AMPERSAND_AMPERSAND || type == TokenType.BAR_BAR) {
      checkForUseOfVoidResult(node.rightOperand);
    } else {
      // Assignability checking is done by the resolver.
    }

    if (type == TokenType.QUESTION_QUESTION) {
      _checkForDeadNullCoalesce(
          node.leftOperand.staticType as TypeImpl, node.rightOperand);
    }

    checkForUseOfVoidResult(node.leftOperand);

    super.visitBinaryExpression(node);
  }

  @override
  void visitBlock(Block node) {
    _withHiddenElements(node.statements, () {
      _duplicateDefinitionVerifier.checkStatements(node.statements);
      super.visitBlock(node);
    });
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    _thisAccessTracker.enterFunctionBody(node);
    try {
      super.visitBlockFunctionBody(node);
    } finally {
      _thisAccessTracker.exitFunctionBody(node);
    }
  }

  @override
  void visitBreakStatement(BreakStatement node) {
    var labelNode = node.label;
    if (labelNode != null) {
      var labelElement = labelNode.staticElement;
      if (labelElement is LabelElementImpl && labelElement.isOnSwitchMember) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.BREAK_LABEL_ON_SWITCH_MEMBER, labelNode);
      }
    }
  }

  @override
  void visitCatchClause(CatchClause node) {
    _duplicateDefinitionVerifier.checkCatchClause(node);
    try {
      _enclosingExecutable.catchClauseLevel++;
      _checkForTypeAnnotationDeferredClass(node.exceptionType);
      super.visitCatchClause(node);
    } finally {
      _enclosingExecutable.catchClauseLevel--;
    }
  }

  @override
  void visitClassDeclaration(covariant ClassDeclarationImpl node) {
    var outerClass = _enclosingClass;
    try {
      final element = node.declaredElement!;
      final augmented = element.augmented;
      if (augmented == null) {
        return;
      }

      _isInNativeClass = node.nativeClause != null;

      final declarationElement = augmented.declaration;
      _enclosingClass = declarationElement;

      List<ClassMember> members = node.members;
      _duplicateDefinitionVerifier.checkClass(node);
      if (!declarationElement.isDartCoreFunctionImpl) {
        _checkForBuiltInIdentifierAsName(
            node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_NAME);
      }
      _checkForConflictingClassTypeVariableErrorCodes();
      var superclass = node.extendsClause?.superclass;
      var implementsClause = node.implementsClause;
      var withClause = node.withClause;

      // Only do error checks on the clause nodes if there is a non-null clause
      if (implementsClause != null ||
          superclass != null ||
          withClause != null) {
        _checkClassInheritance(node, superclass, withClause, implementsClause);
      }

      _checkForConflictingClassMembers();
      _constructorFieldsVerifier.enterClass(node, declarationElement);
      _checkForFinalNotInitializedInClass(members);
      _checkForBadFunctionUse(
        superclass: node.extendsClause?.superclass,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
      );
      _checkForWrongTypeParameterVarianceInSuperinterfaces();
      _checkForMainFunction1(node.name, node.declaredElement!);
      _checkForMixinClassErrorCodes(node, members, superclass, withClause);
      _reportMacroDiagnostics(element, node.metadata);

      GetterSetterTypesVerifier(
        typeSystem: typeSystem,
        errorReporter: errorReporter,
        strictCasts: strictCasts,
      ).checkStaticAccessors(declarationElement.accessors);

      super.visitClassDeclaration(node);
    } finally {
      _isInNativeClass = false;
      _constructorFieldsVerifier.leaveClass();
      _enclosingClass = outerClass;
    }
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    _checkForBuiltInIdentifierAsName(
        node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPEDEF_NAME);
    var outerClassElement = _enclosingClass;
    try {
      _enclosingClass = node.declaredElement as ClassElementImpl;
      _checkClassInheritance(
          node, node.superclass, node.withClause, node.implementsClause);
      _checkForMainFunction1(node.name, node.declaredElement!);
      _checkForMixinClassErrorCodes(
          node, List.empty(), node.superclass, node.withClause);
      _checkForBadFunctionUse(
        superclass: node.superclass,
        withClause: node.withClause,
        implementsClause: node.implementsClause,
      );
      _checkForWrongTypeParameterVarianceInSuperinterfaces();
    } finally {
      _enclosingClass = outerClassElement;
    }
    super.visitClassTypeAlias(node);
  }

  @override
  void visitComment(Comment node) {
    _isInComment = true;
    try {
      super.visitComment(node);
    } finally {
      _isInComment = false;
    }
  }

  @override
  void visitCompilationUnit(CompilationUnit node) {
    var element = node.declaredElement as CompilationUnitElement;
    _featureSet = node.featureSet;
    _duplicateDefinitionVerifier.checkUnit(node);
    _checkForDeferredPrefixCollisions(node);
    _checkForIllegalLanguageOverride(node);

    GetterSetterTypesVerifier(
      typeSystem: typeSystem,
      errorReporter: errorReporter,
      strictCasts: strictCasts,
    ).checkStaticAccessors(element.accessors);

    super.visitCompilationUnit(node);
    _featureSet = null;
  }

  @override
  void visitConstructorDeclaration(
    covariant ConstructorDeclarationImpl node,
  ) {
    var element = node.declaredElement!;
    _withEnclosingExecutable(element, () {
      _checkForNonConstGenerativeEnumConstructor(node);
      _checkForInvalidModifierOnBody(
          node.body, CompileTimeErrorCode.INVALID_MODIFIER_ON_CONSTRUCTOR);
      if (!_checkForConstConstructorWithNonConstSuper(node)) {
        _checkForConstConstructorWithNonFinalField(node, element);
      }
      _constructorFieldsVerifier.verify(node);
      _checkForRedirectingConstructorErrorCodes(node);
      _checkForConflictingInitializerErrorCodes(node);
      _checkForRecursiveConstructorRedirect(node, element);
      if (!_checkForRecursiveFactoryRedirect(node, element)) {
        _checkForAllRedirectConstructorErrorCodes(node);
      }
      _checkForUndefinedConstructorInInitializerImplicit(node);
      _checkForReturnInGenerativeConstructor(node);
      _reportMacroDiagnostics(element, node.metadata);
      super.visitConstructorDeclaration(node);
    });
  }

  @override
  void visitConstructorFieldInitializer(ConstructorFieldInitializer node) {
    _isInConstructorInitializer = true;
    try {
      SimpleIdentifier fieldName = node.fieldName;
      var staticElement = fieldName.staticElement;
      _checkForInvalidField(node, fieldName, staticElement);
      if (staticElement is FieldElement) {
        _checkForAbstractOrExternalFieldConstructorInitializer(
            node.fieldName.token, staticElement);
      }
      super.visitConstructorFieldInitializer(node);
    } finally {
      _isInConstructorInitializer = false;
    }
  }

  @override
  void visitConstructorReference(ConstructorReference node) {
    _typeArgumentsVerifier.checkConstructorReference(node);
    _checkForInvalidGenerativeConstructorReference(node.constructorName);
  }

  @override
  void visitDefaultFormalParameter(DefaultFormalParameter node) {
    final defaultValue = node.defaultValue;
    if (defaultValue != null) {
      checkForAssignableExpressionAtType(
        defaultValue,
        defaultValue.typeOrThrow,
        node.declaredElement!.type,
        CompileTimeErrorCode.INVALID_ASSIGNMENT,
      );
    }

    super.visitDefaultFormalParameter(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    _requiredParametersVerifier.visitEnumConstantDeclaration(node);
    _typeArgumentsVerifier.checkEnumConstantDeclaration(node);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    var outerClass = _enclosingClass;
    try {
      var element = node.declaredElement as EnumElementImpl;
      _enclosingClass = element;
      _duplicateDefinitionVerifier.checkEnum(node);

      _checkForBuiltInIdentifierAsName(
          node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_NAME);
      _checkForConflictingEnumTypeVariableErrorCodes(element);
      var implementsClause = node.implementsClause;
      var withClause = node.withClause;

      if (implementsClause != null || withClause != null) {
        _checkClassInheritance(node, null, withClause, implementsClause);
      }

      _constructorFieldsVerifier.enterEnum(node, element);
      _checkForFinalNotInitializedInClass(node.members);
      _checkForWrongTypeParameterVarianceInSuperinterfaces();
      _checkForMainFunction1(node.name, node.declaredElement!);
      _checkForEnumInstantiatedToBoundsIsNotWellBounded(node, element);

      GetterSetterTypesVerifier(
        typeSystem: typeSystem,
        errorReporter: errorReporter,
        strictCasts: strictCasts,
      ).checkStaticAccessors(element.accessors);

      super.visitEnumDeclaration(node);
    } finally {
      _constructorFieldsVerifier.leaveClass();
      _enclosingClass = outerClass;
    }
  }

  @override
  void visitExportDirective(ExportDirective node) {
    var exportElement = node.element;
    if (exportElement != null) {
      var exportedLibrary = exportElement.exportedLibrary;
      _checkForAmbiguousExport(node, exportElement, exportedLibrary);
      _checkForExportInternalLibrary(node, exportElement);
      _checkForExportLegacySymbol(node);
    }
    super.visitExportDirective(node);
  }

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    _thisAccessTracker.enterFunctionBody(node);
    try {
      _returnTypeVerifier.verifyExpressionFunctionBody(node);
      super.visitExpressionFunctionBody(node);
    } finally {
      _thisAccessTracker.exitFunctionBody(node);
    }
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    var element = node.declaredElement!;
    _enclosingExtension = element;
    _duplicateDefinitionVerifier.checkExtension(node);
    _checkForConflictingExtensionTypeVariableErrorCodes();
    _checkForFinalNotInitializedInClass(node.members);

    GetterSetterTypesVerifier(
      typeSystem: typeSystem,
      errorReporter: errorReporter,
      strictCasts: strictCasts,
    ).checkExtension(element);

    final name = node.name;
    if (name != null) {
      _checkForBuiltInIdentifierAsName(
          name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_EXTENSION_NAME);
    }
    super.visitExtensionDeclaration(node);
    _enclosingExtension = null;
  }

  @override
  void visitExtensionTypeDeclaration(
    covariant ExtensionTypeDeclarationImpl node,
  ) {
    var outerClass = _enclosingClass;
    try {
      final element = node.declaredElement!;
      final augmented = element.augmented;
      if (augmented == null) {
        return;
      }

      final declarationElement = augmented.declaration;
      _enclosingClass = declarationElement;

      _checkForBuiltInIdentifierAsName(node.name,
          CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_EXTENSION_TYPE_NAME);
      _checkForConflictingExtensionTypeTypeVariableErrorCodes(element);

      _duplicateDefinitionVerifier.checkExtensionType(node, declarationElement);
      _checkForRepeatedType(node.implementsClause?.interfaces,
          CompileTimeErrorCode.IMPLEMENTS_REPEATED);
      _checkForConflictingClassMembers();
      _checkForConflictingGenerics(node);
      _constructorFieldsVerifier.enterExtensionType(node, declarationElement);
      _checkForNonCovariantTypeParameterPositionInRepresentationType(
          node, element);
      _checkForExtensionTypeRepresentationDependsOnItself(node, element);
      _checkForExtensionTypeRepresentationTypeBottom(node, element);
      _checkForExtensionTypeImplementsDeferred(node);
      _checkForExtensionTypeImplementsItself(node, element);
      _checkForExtensionTypeMemberConflicts(
        node: node,
        element: element,
      );
      _checkForExtensionTypeWithAbstractMember(node);
      _checkForWrongTypeParameterVarianceInSuperinterfaces();

      final interface = _inheritanceManager.getInterface(element);
      GetterSetterTypesVerifier(
        typeSystem: typeSystem,
        errorReporter: errorReporter,
        strictCasts: strictCasts,
      ).checkExtensionType(element, interface);

      super.visitExtensionTypeDeclaration(node);
    } finally {
      _constructorFieldsVerifier.leaveClass();
      _enclosingClass = outerClass;
    }
  }

  @override
  void visitFieldDeclaration(covariant FieldDeclarationImpl node) {
    var fields = node.fields;
    _thisAccessTracker.enterFieldDeclaration(node);
    _isInStaticVariableDeclaration = node.isStatic;
    _isInInstanceNotLateVariableDeclaration =
        !node.isStatic && !node.fields.isLate;
    if (!_isInStaticVariableDeclaration) {
      if (fields.isConst) {
        errorReporter.reportErrorForToken(
            CompileTimeErrorCode.CONST_INSTANCE_FIELD, fields.keyword!);
      }
    }
    try {
      _checkForExtensionTypeDeclaresInstanceField(node);
      _checkForNotInitializedNonNullableStaticField(node);
      _checkForWrongTypeParameterVarianceInField(node);
      _checkForLateFinalFieldWithConstConstructor(node);
      _checkForNonFinalFieldInEnum(node);

      for (final field in fields.variables) {
        if (field.declaredElement case final FieldElementImpl element) {
          _reportMacroDiagnostics(element, node.metadata);
        }
      }

      super.visitFieldDeclaration(node);
    } finally {
      _isInStaticVariableDeclaration = false;
      _isInInstanceNotLateVariableDeclaration = false;
      _thisAccessTracker.exitFieldDeclaration(node);
    }
  }

  @override
  void visitFieldFormalParameter(FieldFormalParameter node) {
    _checkForValidField(node);
    _checkForPrivateOptionalParameter(node);
    _checkForFieldInitializingFormalRedirectingConstructor(node);
    _checkForTypeAnnotationDeferredClass(node.type);
    ParameterElement element = node.declaredElement!;
    if (element is FieldFormalParameterElement) {
      var fieldElement = element.field;
      if (fieldElement != null) {
        _checkForAbstractOrExternalFieldConstructorInitializer(
            node.name, fieldElement);
      }
    }
    super.visitFieldFormalParameter(node);
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    DeclaredIdentifier loopVariable = node.loopVariable;
    if (_checkForEachParts(node, loopVariable.declaredElement)) {
      if (loopVariable.isConst) {
        errorReporter.reportErrorForToken(
            CompileTimeErrorCode.FOR_IN_WITH_CONST_VARIABLE,
            loopVariable.keyword!);
      }
    }
    super.visitForEachPartsWithDeclaration(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    SimpleIdentifier identifier = node.identifier;
    if (_checkForEachParts(node, identifier.staticElement)) {
      _checkForAssignmentToFinal(identifier);
    }
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitFormalParameterList(FormalParameterList node) {
    _duplicateDefinitionVerifier.checkParameters(node);
    _checkUseOfCovariantInParameters(node);
    _checkUseOfDefaultValuesInParameters(node);
    super.visitFormalParameterList(node);
  }

  @override
  void visitForPartsWithDeclarations(ForPartsWithDeclarations node) {
    _duplicateDefinitionVerifier.checkForVariables(node.variables);
    super.visitForPartsWithDeclarations(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    ExecutableElement functionElement = node.declaredElement!;
    if (functionElement.enclosingElement is! CompilationUnitElement) {
      _hiddenElements!.declare(functionElement);
    }

    _withEnclosingExecutable(functionElement, () {
      TypeAnnotation? returnType = node.returnType;
      if (node.isSetter) {
        FunctionExpression functionExpression = node.functionExpression;
        _checkForWrongNumberOfParametersForSetter(
            node.name, functionExpression.parameters);
        _checkForNonVoidReturnTypeForSetter(returnType);
      }
      _checkForTypeAnnotationDeferredClass(returnType);
      _returnTypeVerifier.verifyReturnType(returnType);
      _checkForMainFunction1(node.name, node.declaredElement!);
      _checkForMainFunction2(node);
      super.visitFunctionDeclaration(node);
    });
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _isInLateLocalVariable.add(false);

    if (node.parent is FunctionDeclaration) {
      super.visitFunctionExpression(node);
    } else {
      _withEnclosingExecutable(node.declaredElement!, () {
        super.visitFunctionExpression(node);
      });
    }

    _isInLateLocalVariable.removeLast();
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    Expression functionExpression = node.function;

    if (functionExpression is ExtensionOverride) {
      return super.visitFunctionExpressionInvocation(node);
    }

    DartType expressionType = functionExpression.typeOrThrow;
    if (expressionType is FunctionType) {
      _typeArgumentsVerifier.checkFunctionExpressionInvocation(node);
    }
    _requiredParametersVerifier.visitFunctionExpressionInvocation(node);
    _checkUseVerifier.checkFunctionExpressionInvocation(node);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    _typeArgumentsVerifier.checkFunctionReference(node);
    super.visitFunctionReference(node);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    _checkForBuiltInIdentifierAsName(
        node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPEDEF_NAME);
    _checkForMainFunction1(node.name, node.declaredElement!);
    _checkForTypeAliasCannotReferenceItself(
        node.name, node.declaredElement as TypeAliasElementImpl);
    super.visitFunctionTypeAlias(node);
  }

  @override
  void visitFunctionTypedFormalParameter(FunctionTypedFormalParameter node) {
    bool old = _isInFunctionTypedFormalParameter;
    _isInFunctionTypedFormalParameter = true;
    try {
      _checkForTypeAnnotationDeferredClass(node.returnType);

      super.visitFunctionTypedFormalParameter(node);
    } finally {
      _isInFunctionTypedFormalParameter = old;
    }
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _checkForBuiltInIdentifierAsName(
        node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPEDEF_NAME);
    _checkForMainFunction1(node.name, node.declaredElement!);
    _checkForTypeAliasCannotReferenceItself(
        node.name, node.declaredElement as TypeAliasElementImpl);
    super.visitGenericTypeAlias(node);
  }

  @override
  void visitGuardedPattern(covariant GuardedPatternImpl node) {
    _withHiddenElementsGuardedPattern(node, () {
      node.pattern.accept(this);
    });
    node.whenClause?.accept(this);
  }

  @override
  void visitImportDirective(ImportDirective node) {
    var importElement = node.element;
    if (node.prefix != null) {
      _checkForBuiltInIdentifierAsName(node.prefix!.token,
          CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_PREFIX_NAME);
    }
    if (importElement != null) {
      _checkForImportInternalLibrary(node, importElement);
      if (importElement.prefix is DeferredImportElementPrefix) {
        _checkForDeferredImportOfExtensions(node, importElement);
      }
    }
    super.visitImportDirective(node);
  }

  @override
  void visitImportPrefixReference(ImportPrefixReference node) {
    _checkForReferenceBeforeDeclaration(
      nameToken: node.name,
      element: node.element,
    );
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    if (node.isNullAware) {
      _checkForUnnecessaryNullAware(
        node.realTarget,
        node.question ?? node.period ?? node.leftBracket,
      );
    }

    super.visitIndexExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    ConstructorName constructorName = node.constructorName;
    NamedType namedType = constructorName.type;
    DartType type = namedType.typeOrThrow;
    if (type is InterfaceType) {
      _checkForConstOrNewWithAbstractClass(node, namedType, type);
      _checkForInvalidGenerativeConstructorReference(constructorName);
      _checkForConstOrNewWithMixin(node, namedType, type);
      _requiredParametersVerifier.visitInstanceCreationExpression(node);
      if (node.isConst) {
        _checkForConstWithNonConst(node);
        _checkForConstWithUndefinedConstructor(
            node, constructorName, namedType);
        _checkForConstDeferredClass(node, constructorName, namedType);
      } else {
        _checkForNewWithUndefinedConstructor(node, constructorName, namedType);
      }
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitIntegerLiteral(IntegerLiteral node) {
    _checkForOutOfRange(node);
    super.visitIntegerLiteral(node);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    checkForUseOfVoidResult(node.expression);
    super.visitInterpolationExpression(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    _checkForTypeAnnotationDeferredClass(node.type);
    checkForUseOfVoidResult(node.expression);
    super.visitIsExpression(node);
  }

  @override
  void visitListLiteral(ListLiteral node) {
    _typeArgumentsVerifier.checkListLiteral(node);
    _checkForListElementTypeNotAssignable(node);

    super.visitListLiteral(node);
  }

  @override
  void visitMethodDeclaration(covariant MethodDeclarationImpl node) {
    final element = node.declaredElement!;
    _withEnclosingExecutable(element, () {
      var returnType = node.returnType;
      if (node.isSetter) {
        _checkForWrongNumberOfParametersForSetter(node.name, node.parameters);
        _checkForNonVoidReturnTypeForSetter(returnType);
      } else if (node.isOperator) {
        var hasWrongNumberOfParameters =
            _checkForWrongNumberOfParametersForOperator(node);
        if (!hasWrongNumberOfParameters) {
          // If the operator has too many parameters including one or more
          // optional parameters, only report one error.
          _checkForOptionalParameterInOperator(node);
        }
        _checkForNonVoidReturnTypeForOperator(node);
      }
      _checkForExtensionDeclaresMemberOfObject(node);
      _checkForTypeAnnotationDeferredClass(returnType);
      _returnTypeVerifier.verifyReturnType(returnType);
      _checkForWrongTypeParameterVarianceInMethod(node);
      _reportMacroDiagnostics(element, node.metadata);
      super.visitMethodDeclaration(node);
    });
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    var target = node.realTarget;
    SimpleIdentifier methodName = node.methodName;
    if (target != null) {
      var typeReference = ElementResolver.getTypeReference(target);
      _checkForStaticAccessToInstanceMember(typeReference, methodName);
      _checkForInstanceAccessToStaticMember(
          typeReference, node.target, methodName);
      _checkForUnnecessaryNullAware(target, node.operator!);
    } else {
      _checkForUnqualifiedReferenceToNonLocalStaticMember(methodName);
    }
    _typeArgumentsVerifier.checkMethodInvocation(node);
    _requiredParametersVerifier.visitMethodInvocation(node);
    _checkUseVerifier.checkMethodInvocation(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitMixinDeclaration(covariant MixinDeclarationImpl node) {
    // TODO(scheglov): Verify for all mixin errors.
    var outerClass = _enclosingClass;
    try {
      final element = node.declaredElement!;
      final augmented = element.augmented;
      if (augmented == null) {
        return;
      }

      final declarationElement = augmented.declaration;
      _enclosingClass = declarationElement;

      List<ClassMember> members = node.members;
      _duplicateDefinitionVerifier.checkMixin(node);
      _checkForBuiltInIdentifierAsName(
          node.name, CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_NAME);
      _checkForConflictingClassTypeVariableErrorCodes();

      var onClause = node.onClause;
      var implementsClause = node.implementsClause;

      // Only do error checks only if there is a non-null clause.
      if (onClause != null || implementsClause != null) {
        _checkMixinInheritance(node, onClause, implementsClause);
      }

      _checkForConflictingClassMembers();
      _checkForFinalNotInitializedInClass(members);
      _checkForMainFunction1(node.name, declarationElement);
      _checkForWrongTypeParameterVarianceInSuperinterfaces();
      _reportMacroDiagnostics(element, node.metadata);
      //      _checkForBadFunctionUse(node);
      super.visitMixinDeclaration(node);
    } finally {
      _enclosingClass = outerClass;
    }
  }

  @override
  void visitNamedType(NamedType node) {
    _checkForAmbiguousImport(
      name: node.name2,
      element: node.element,
    );
    _checkForTypeParameterReferencedByStatic(
      name: node.name2,
      element: node.element,
    );
    _typeArgumentsVerifier.checkNamedType(node);
    super.visitNamedType(node);
  }

  @override
  void visitNativeClause(NativeClause node) {
    // TODO(brianwilkerson): Figure out the right rule for when 'native' is
    // allowed.
    if (!_isInSystemLibrary) {
      errorReporter.reportErrorForNode(
          ParserErrorCode.NATIVE_CLAUSE_IN_NON_SDK_CODE, node);
    }
    super.visitNativeClause(node);
  }

  @override
  void visitNativeFunctionBody(NativeFunctionBody node) {
    _checkForNativeFunctionBodyInNonSdkCode(node);
    super.visitNativeFunctionBody(node);
  }

  @override
  void visitPatternVariableDeclarationStatement(
    covariant PatternVariableDeclarationStatementImpl node,
  ) {
    super.visitPatternVariableDeclarationStatement(node);
    for (var variable in node.declaration.elements) {
      _hiddenElements?.declare(variable);
    }
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    var operand = node.operand;
    if (node.operator.type == TokenType.BANG) {
      checkForUseOfVoidResult(node);
      _checkForUnnecessaryNullAware(operand, node.operator);
    } else {
      _checkForAssignmentToFinal(operand);
      _checkForIntNotAssignable(operand);
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.parent is! Annotation) {
      var typeReference = ElementResolver.getTypeReference(node.prefix);
      SimpleIdentifier name = node.identifier;
      _checkForStaticAccessToInstanceMember(typeReference, name);
      _checkForInstanceAccessToStaticMember(typeReference, node.prefix, name);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    TokenType operatorType = node.operator.type;
    Expression operand = node.operand;
    if (operatorType != TokenType.BANG) {
      if (operatorType.isIncrementOperator) {
        _checkForAssignmentToFinal(operand);
      }
      checkForUseOfVoidResult(operand);
      _checkForIntNotAssignable(operand);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    var target = node.realTarget;
    var typeReference = ElementResolver.getTypeReference(target);
    SimpleIdentifier propertyName = node.propertyName;
    _checkForStaticAccessToInstanceMember(typeReference, propertyName);
    _checkForInstanceAccessToStaticMember(
        typeReference, node.target, propertyName);
    _checkForUnnecessaryNullAware(target, node.operator);
    _checkUseVerifier.checkPropertyAccess(node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
      RedirectingConstructorInvocation node) {
    _requiredParametersVerifier.visitRedirectingConstructorInvocation(node);
    _isInConstructorInitializer = true;
    try {
      super.visitRedirectingConstructorInvocation(node);
    } finally {
      _isInConstructorInitializer = false;
    }
  }

  @override
  void visitRethrowExpression(RethrowExpression node) {
    _checkForRethrowOutsideCatch(node);
    super.visitRethrowExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression == null) {
      _enclosingExecutable._returnsWithout.add(node);
    } else {
      _enclosingExecutable._returnsWith.add(node);
    }
    _returnTypeVerifier.verifyReturnStatement(node);
    super.visitReturnStatement(node);
  }

  @override
  void visitSetOrMapLiteral(SetOrMapLiteral node) {
    if (node.isMap) {
      _typeArgumentsVerifier.checkMapLiteral(node);
      _checkForMapTypeNotAssignable(node);
      _checkForNonConstMapAsExpressionStatement3(node);
    } else if (node.isSet) {
      _typeArgumentsVerifier.checkSetLiteral(node);
      _checkForSetElementTypeNotAssignable3(node);
    }
    super.visitSetOrMapLiteral(node);
  }

  @override
  void visitSimpleFormalParameter(SimpleFormalParameter node) {
    _checkForPrivateOptionalParameter(node);
    _checkForTypeAnnotationDeferredClass(node.type);
    super.visitSimpleFormalParameter(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _checkForAmbiguousImport(
      name: node.token,
      element: node.writeOrReadElement,
    );
    _checkForReferenceBeforeDeclaration(
      nameToken: node.token,
      element: node.staticElement,
    );
    _checkForInvalidInstanceMemberAccess(node);
    _checkForTypeParameterReferencedByStatic(
      name: node.token,
      element: node.staticElement,
    );
    if (!_isUnqualifiedReferenceToNonLocalStaticMemberAllowed(node)) {
      _checkForUnqualifiedReferenceToNonLocalStaticMember(node);
    }
    _checkUseVerifier.checkSimpleIdentifier(node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    if (node.isNullAware) {
      _checkForUnnecessaryNullAware(node.expression, node.spreadOperator);
    }
    super.visitSpreadElement(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _requiredParametersVerifier.visitSuperConstructorInvocation(
      node,
      enclosingConstructor: _enclosingExecutable.element.ifTypeOrNull(),
    );
    _isInConstructorInitializer = true;
    try {
      _checkForExtensionTypeConstructorWithSuperInvocation(node);
      super.visitSuperConstructorInvocation(node);
    } finally {
      _isInConstructorInitializer = false;
    }
  }

  @override
  void visitSuperFormalParameter(SuperFormalParameter node) {
    super.visitSuperFormalParameter(node);

    if (_enclosingClass is ExtensionTypeElement) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode
            .EXTENSION_TYPE_CONSTRUCTOR_WITH_SUPER_FORMAL_PARAMETER,
        node.superKeyword,
      );
      return;
    }

    var constructor = node.parentFormalParameterList.parent;
    if (!(constructor is ConstructorDeclaration &&
        constructor.isNonRedirectingGenerative)) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.INVALID_SUPER_FORMAL_PARAMETER_LOCATION,
        node.superKeyword,
      );
      return;
    }

    var element = node.declaredElement as SuperFormalParameterElementImpl;
    var superParameter = element.superConstructorParameter;

    if (superParameter == null) {
      errorReporter.reportErrorForToken(
        node.isNamed
            ? CompileTimeErrorCode
                .SUPER_FORMAL_PARAMETER_WITHOUT_ASSOCIATED_NAMED
            : CompileTimeErrorCode
                .SUPER_FORMAL_PARAMETER_WITHOUT_ASSOCIATED_POSITIONAL,
        node.name,
      );
      return;
    }

    if (!_currentLibrary.typeSystem
        .isSubtypeOf(element.type, superParameter.type)) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode
            .SUPER_FORMAL_PARAMETER_TYPE_IS_NOT_SUBTYPE_OF_ASSOCIATED,
        node.name,
        [element.type, superParameter.type],
      );
    }
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    _withHiddenElements(node.statements, () {
      _duplicateDefinitionVerifier.checkStatements(node.statements);
      super.visitSwitchCase(node);
    });
  }

  @override
  void visitSwitchDefault(SwitchDefault node) {
    _withHiddenElements(node.statements, () {
      _duplicateDefinitionVerifier.checkStatements(node.statements);
      super.visitSwitchDefault(node);
    });
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    checkForUseOfVoidResult(node.expression);
    super.visitSwitchExpression(node);
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    _withHiddenElements(node.statements, () {
      _duplicateDefinitionVerifier.checkStatements(node.statements);
      super.visitSwitchPatternCase(node);
    });
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    checkForUseOfVoidResult(node.expression);
    _checkForCaseBlocksNotTerminated(node);
    _checkForMissingEnumConstantInSwitch(node);
    super.visitSwitchStatement(node);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    _checkForInvalidReferenceToThis(node);
    super.visitThisExpression(node);
  }

  @override
  void visitThrowExpression(ThrowExpression node) {
    _checkForConstEvalThrowsException(node);
    checkForUseOfVoidResult(node.expression);
    _checkForThrowOfInvalidType(node);
    super.visitThrowExpression(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    _checkForFinalNotInitialized(node.variables);
    _checkForNotInitializedNonNullableVariable(node.variables, true);

    for (var variable in node.variables.variables) {
      _checkForMainFunction1(variable.name, variable.declaredElement!);
    }

    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitTypeArgumentList(TypeArgumentList node) {
    NodeList<TypeAnnotation> list = node.arguments;
    for (TypeAnnotation type in list) {
      _checkForTypeAnnotationDeferredClass(type);
    }
    super.visitTypeArgumentList(node);
  }

  @override
  void visitTypeParameter(TypeParameter node) {
    _checkForBuiltInIdentifierAsName(node.name,
        CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_PARAMETER_NAME);
    _checkForTypeAnnotationDeferredClass(node.bound);
    _checkForGenericFunctionType(node.bound);
    node.bound?.accept(_uninstantiatedBoundChecker);
    super.visitTypeParameter(node);
  }

  @override
  void visitTypeParameterList(TypeParameterList node) {
    _duplicateDefinitionVerifier.checkTypeParameters(node);
    _checkForTypeParameterBoundRecursion(node.typeParameters);
    super.visitTypeParameterList(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final nameToken = node.name;
    var initializerNode = node.initializer;
    // do checks
    _checkForAbstractOrExternalVariableInitializer(node);
    // visit initializer
    String name = nameToken.lexeme;
    _namesForReferenceToDeclaredVariableInInitializer.add(name);
    try {
      if (initializerNode != null) {
        initializerNode.accept(this);
      }
    } finally {
      _namesForReferenceToDeclaredVariableInInitializer.remove(name);
    }
    // declare the variable
    AstNode grandparent = node.parent!.parent!;
    if (grandparent is! TopLevelVariableDeclaration &&
        grandparent is! FieldDeclaration) {
      VariableElement element = node.declaredElement!;
      // There is no hidden elements if we are outside of a function body,
      // which will happen for variables declared in control flow elements.
      _hiddenElements?.declare(element);
    }
  }

  @override
  void visitVariableDeclarationList(VariableDeclarationList node) {
    _checkForTypeAnnotationDeferredClass(node.type);
    super.visitVariableDeclarationList(node);
  }

  @override
  void visitVariableDeclarationStatement(VariableDeclarationStatement node) {
    _isInLateLocalVariable.add(node.variables.isLate);

    _checkForFinalNotInitialized(node.variables);
    super.visitVariableDeclarationStatement(node);

    _isInLateLocalVariable.removeLast();
  }

  /// Checks the class for problems with the superclass, mixins, or implemented
  /// interfaces.
  void _checkClassInheritance(
      NamedCompilationUnitMember node,
      NamedType? superclass,
      WithClause? withClause,
      ImplementsClause? implementsClause) {
    // Only check for all of the inheritance logic around clauses if there
    // isn't an error code such as "Cannot extend double" already on the
    // class.
    if (!_checkForExtendsDisallowedClass(superclass) &&
        !_checkForImplementsClauseErrorCodes(implementsClause) &&
        !_checkForAllMixinErrorCodes(withClause) &&
        !_checkForNoGenerativeConstructorsInSuperclass(superclass)) {
      _checkForExtendsDeferredClass(superclass);
      _checkForRepeatedType(implementsClause?.interfaces,
          CompileTimeErrorCode.IMPLEMENTS_REPEATED);
      _checkImplementsSuperClass(implementsClause);
      _checkMixinsSuperClass(withClause);
      _checkForMixinWithConflictingPrivateMember(withClause, superclass);
      _checkForConflictingGenerics(node);
      _checkForBaseClassOrMixinImplementedOutsideOfLibrary(implementsClause);
      _checkForInterfaceClassOrMixinSuperclassOutsideOfLibrary(
          superclass, withClause);
      _checkForFinalSupertypeOutsideOfLibrary(
          superclass, withClause, implementsClause, null);
      _checkForClassUsedAsMixin(withClause);
      _checkForSealedSupertypeOutsideOfLibrary(
          superclass, withClause, implementsClause, null);
      if (node is ClassDeclaration) {
        _checkForNoDefaultSuperConstructorImplicit(node);
      }
    }
  }

  /// Given a list of [directives] that have the same prefix, generate an error
  /// if there is more than one import and any of those imports is deferred.
  ///
  /// See [CompileTimeErrorCode.SHARED_DEFERRED_PREFIX].
  void _checkDeferredPrefixCollision(List<ImportDirective> directives) {
    int count = directives.length;
    if (count > 1) {
      for (int i = 0; i < count; i++) {
        var deferredToken = directives[i].deferredKeyword;
        if (deferredToken != null) {
          errorReporter.reportErrorForToken(
              CompileTimeErrorCode.SHARED_DEFERRED_PREFIX, deferredToken);
        }
      }
    }
  }

  void _checkForAbstractOrExternalFieldConstructorInitializer(
      Token identifier, FieldElement fieldElement) {
    if (fieldElement.isAbstract) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.ABSTRACT_FIELD_CONSTRUCTOR_INITIALIZER,
          identifier);
    }
    if (fieldElement.isExternal) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.EXTERNAL_FIELD_CONSTRUCTOR_INITIALIZER,
          identifier);
    }
  }

  void _checkForAbstractOrExternalVariableInitializer(
      VariableDeclaration node) {
    var declaredElement = node.declaredElement;
    if (node.initializer != null) {
      if (declaredElement is FieldElement) {
        if (declaredElement.isAbstract) {
          errorReporter.reportErrorForToken(
              CompileTimeErrorCode.ABSTRACT_FIELD_INITIALIZER, node.name);
        }
        if (declaredElement.isExternal) {
          errorReporter.reportErrorForToken(
              CompileTimeErrorCode.EXTERNAL_FIELD_INITIALIZER, node.name);
        }
      } else if (declaredElement is TopLevelVariableElement) {
        if (declaredElement.isExternal) {
          errorReporter.reportErrorForToken(
              CompileTimeErrorCode.EXTERNAL_VARIABLE_INITIALIZER, node.name);
        }
      }
    }
  }

  /// Verify that all classes of the given [withClause] are valid.
  ///
  /// See [CompileTimeErrorCode.MIXIN_CLASS_DECLARES_CONSTRUCTOR],
  /// [CompileTimeErrorCode.MIXIN_INHERITS_FROM_NOT_OBJECT].
  bool _checkForAllMixinErrorCodes(WithClause? withClause) {
    if (withClause == null) {
      return false;
    }
    bool problemReported = false;
    int mixinTypeIndex = -1;
    for (int mixinNameIndex = 0;
        mixinNameIndex < withClause.mixinTypes.length;
        mixinNameIndex++) {
      NamedType mixinName = withClause.mixinTypes[mixinNameIndex];
      DartType mixinType = mixinName.typeOrThrow;
      if (mixinType is InterfaceType) {
        mixinTypeIndex++;
        if (_checkForExtendsOrImplementsDisallowedClass(
            mixinName, CompileTimeErrorCode.MIXIN_OF_DISALLOWED_CLASS)) {
          problemReported = true;
        } else {
          final mixinElement = mixinType.element;
          if (_checkForExtendsOrImplementsDeferredClass(
              mixinName, CompileTimeErrorCode.MIXIN_DEFERRED_CLASS)) {
            problemReported = true;
          }
          if (mixinType.element is ExtensionTypeElement) {
            // Already reported.
          } else if (mixinElement is MixinElement) {
            if (_checkForMixinSuperclassConstraints(
                mixinNameIndex, mixinName)) {
              problemReported = true;
            } else if (_checkForMixinSuperInvokedMembers(
                mixinTypeIndex, mixinName, mixinElement, mixinType)) {
              problemReported = true;
            }
          } else {
            bool isMixinClass =
                mixinElement is ClassElementImpl && mixinElement.isMixinClass;
            if (!isMixinClass &&
                _checkForMixinClassDeclaresConstructor(
                    mixinName, mixinElement)) {
              problemReported = true;
            }
            if (_checkForMixinInheritsNotFromObject(mixinName, mixinElement)) {
              problemReported = true;
            }
          }
        }
      }
    }
    return problemReported;
  }

  /// Check for errors related to the redirected constructors.
  void _checkForAllRedirectConstructorErrorCodes(
      ConstructorDeclaration declaration) {
    // Prepare redirected constructor node
    var redirectedConstructor = declaration.redirectedConstructor;
    if (redirectedConstructor == null) {
      return;
    }

    // Prepare redirected constructor type
    var redirectedElement = redirectedConstructor.staticElement;
    if (redirectedElement == null) {
      // If the element is null, we check for the
      // REDIRECT_TO_MISSING_CONSTRUCTOR case
      NamedType constructorNamedType = redirectedConstructor.type;
      DartType redirectedType = constructorNamedType.typeOrThrow;
      if (!(redirectedType is DynamicType || redirectedType is InvalidType)) {
        // Prepare the constructor name
        String constructorStrName = constructorNamedType.qualifiedName;
        if (redirectedConstructor.name != null) {
          constructorStrName += ".${redirectedConstructor.name!.name}";
        }
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.REDIRECT_TO_MISSING_CONSTRUCTOR,
            redirectedConstructor,
            [constructorStrName, redirectedType]);
      }
      return;
    }
    FunctionType redirectedType = redirectedElement.type;
    DartType redirectedReturnType = redirectedType.returnType;

    // Report specific problem when return type is incompatible
    FunctionType constructorType = declaration.declaredElement!.type;
    DartType constructorReturnType = constructorType.returnType;
    if (!typeSystem.isAssignableTo(redirectedReturnType, constructorReturnType,
        strictCasts: strictCasts)) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.REDIRECT_TO_INVALID_RETURN_TYPE,
          redirectedConstructor,
          [redirectedReturnType, constructorReturnType]);
      return;
    } else if (!typeSystem.isSubtypeOf(redirectedType, constructorType)) {
      // Check parameters.
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.REDIRECT_TO_INVALID_FUNCTION_TYPE,
          redirectedConstructor,
          [redirectedType, constructorType]);
    }
  }

  /// Verify that the export namespace of the given export [directive] does not
  /// export any name already exported by another export directive. The
  /// [exportElement] is the [LibraryExportElement] retrieved from the node. If the
  /// element in the node was `null`, then this method is not called. The
  /// [exportedLibrary] is the library element containing the exported element.
  ///
  /// See [CompileTimeErrorCode.AMBIGUOUS_EXPORT].
  void _checkForAmbiguousExport(ExportDirective directive,
      LibraryExportElement exportElement, LibraryElement? exportedLibrary) {
    if (exportedLibrary == null) {
      return;
    }
    // check exported names
    Namespace namespace =
        NamespaceBuilder().createExportNamespaceForDirective(exportElement);
    Map<String, Element> definedNames = namespace.definedNames;
    for (String name in definedNames.keys) {
      var element = definedNames[name]!;
      var prevElement = _exportedElements[name];
      if (prevElement != null && prevElement != element) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.AMBIGUOUS_EXPORT, directive.uri, [
          name,
          prevElement.library!.definingCompilationUnit.source.uri,
          element.library!.definingCompilationUnit.source.uri
        ]);
        return;
      } else {
        _exportedElements[name] = element;
      }
    }
  }

  /// Check the given node to see whether it was ambiguous because the name was
  /// imported from two or more imports.
  void _checkForAmbiguousImport({
    required Token name,
    required Element? element,
  }) {
    if (element is MultiplyDefinedElementImpl) {
      var conflictingMembers = element.conflictingElements;
      var libraryNames =
          conflictingMembers.map((e) => _getLibraryName(e)).toList();
      libraryNames.sort();
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.AMBIGUOUS_IMPORT,
        name,
        [name.lexeme, libraryNames.quotedAndCommaSeparatedWithAnd],
      );
    }
  }

  /// Verify that the given [expression] is not final.
  ///
  /// See [CompileTimeErrorCode.ASSIGNMENT_TO_CONST],
  /// [CompileTimeErrorCode.ASSIGNMENT_TO_FINAL], and
  /// [CompileTimeErrorCode.ASSIGNMENT_TO_METHOD].
  void _checkForAssignmentToFinal(Expression expression) {
    // TODO(scheglov): Check SimpleIdentifier(s) as all other nodes.
    if (expression is! SimpleIdentifier) return;

    // Already handled in the assignment resolver.
    if (expression.parent is AssignmentExpression) {
      return;
    }

    // prepare element
    var highlightedNode = expression;
    var element = expression.staticElement;
    if (expression is PrefixedIdentifier) {
      var prefixedIdentifier = expression as PrefixedIdentifier;
      highlightedNode = prefixedIdentifier.identifier;
    }
    // check if element is assignable
    if (element is VariableElement) {
      if (element.isConst) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_CONST,
          expression,
        );
      } else if (element.isFinal) {
        if (_isNonNullableByDefault) {
          // Handled during resolution, with flow analysis.
        } else {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.ASSIGNMENT_TO_FINAL_LOCAL,
            expression,
            [element.name],
          );
        }
      }
    } else if (element is PropertyAccessorElement && element.isGetter) {
      var variable = element.variable;
      if (variable.isConst) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_CONST,
          expression,
        );
      } else if (variable is FieldElement && variable.isSynthetic) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_FINAL_NO_SETTER,
          highlightedNode,
          [variable.name, variable.enclosingElement.displayName],
        );
      } else {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_FINAL,
          highlightedNode,
          [variable.name],
        );
      }
    } else if (element is FunctionElement) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_FUNCTION, expression);
    } else if (element is MethodElement) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_METHOD, expression);
    } else if (element is InterfaceElement ||
        element is DynamicElementImpl ||
        element is TypeParameterElement) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.ASSIGNMENT_TO_TYPE, expression);
    }
  }

  void _checkForAwaitInLateLocalVariableInitializer(AwaitExpression node) {
    if (_isInLateLocalVariable.last) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.AWAIT_IN_LATE_LOCAL_VARIABLE_INITIALIZER,
        node.awaitKeyword,
      );
    }
  }

  void _checkForAwaitOfExtensionTypeNotFuture(AwaitExpression node) {
    final expression = node.expression;
    final expressionType = expression.typeOrThrow;
    if (expressionType.element is ExtensionTypeElement) {
      final anyFuture = typeSystem.typeProvider.futureType(
        typeSystem.objectQuestion,
      );
      if (!typeSystem.isSubtypeOf(expressionType, anyFuture)) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.AWAIT_OF_EXTENSION_TYPE_NOT_FUTURE,
          node.awaitKeyword,
        );
      }
    }
  }

  /// Verifies that the nodes don't reference `Function` from `dart:core`.
  void _checkForBadFunctionUse({
    required NamedType? superclass,
    required ImplementsClause? implementsClause,
    required WithClause? withClause,
  }) {
    // With the `class_modifiers` feature `Function` is final.
    if (_featureSet!.isEnabled(Feature.class_modifiers)) {
      return;
    }

    if (superclass != null) {
      var type = superclass.type;
      if (type != null && type.isDartCoreFunction) {
        errorReporter.reportErrorForNode(
          WarningCode.DEPRECATED_EXTENDS_FUNCTION,
          superclass,
        );
      }
    }

    if (implementsClause != null) {
      for (var interface in implementsClause.interfaces) {
        var type = interface.type;
        if (type != null && type.isDartCoreFunction) {
          errorReporter.reportErrorForNode(
            WarningCode.DEPRECATED_IMPLEMENTS_FUNCTION,
            interface,
          );
          break;
        }
      }
    }

    if (withClause != null) {
      for (NamedType mixin in withClause.mixinTypes) {
        final type = mixin.type;
        if (type != null && type.isDartCoreFunction) {
          errorReporter.reportErrorForNode(
            WarningCode.DEPRECATED_MIXIN_FUNCTION,
            mixin,
          );
        }
      }
    }
  }

  /// Verify that if a class is implementing a base class or mixin, it must be
  /// within the same library as that class or mixin.
  ///
  /// See [CompileTimeErrorCode.BASE_CLASS_IMPLEMENTED_OUTSIDE_OF_LIBRARY],
  /// [CompileTimeErrorCode.BASE_MIXIN_IMPLEMENTED_OUTSIDE_OF_LIBRARY].
  void _checkForBaseClassOrMixinImplementedOutsideOfLibrary(
      ImplementsClause? implementsClause) {
    if (implementsClause == null) return;
    for (NamedType interface in implementsClause.interfaces) {
      final interfaceType = interface.type;
      if (interfaceType is InterfaceType) {
        final implementedInterfaces = [
          interfaceType,
          ...interfaceType.element.allSupertypes,
        ].map((e) => e.element).toList();
        for (final interfaceElement in implementedInterfaces) {
          if (interfaceElement is ClassOrMixinElementImpl &&
              interfaceElement.isBase &&
              interfaceElement.library != _currentLibrary &&
              !_mayIgnoreClassModifiers(interfaceElement.library)) {
            // Should this be combined with _checkForImplementsClauseErrorCodes
            // to avoid double errors if implementing `int`.
            if (interfaceElement is ClassElementImpl &&
                !interfaceElement.isSealed) {
              errorReporter.reportErrorForNode(
                  CompileTimeErrorCode
                      .BASE_CLASS_IMPLEMENTED_OUTSIDE_OF_LIBRARY,
                  interface,
                  [interfaceElement.name]);
            } else if (interfaceElement is MixinElement) {
              errorReporter.reportErrorForNode(
                  CompileTimeErrorCode
                      .BASE_MIXIN_IMPLEMENTED_OUTSIDE_OF_LIBRARY,
                  interface,
                  [interfaceElement.name]);
            }
            break;
          }
        }
      }
    }
  }

  /// Verify that the given [token] is not a keyword, and generates the
  /// given [errorCode] on the identifier if it is a keyword.
  ///
  /// See [CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_EXTENSION_NAME],
  /// [CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_NAME],
  /// [CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPE_PARAMETER_NAME], and
  /// [CompileTimeErrorCode.BUILT_IN_IDENTIFIER_AS_TYPEDEF_NAME].
  void _checkForBuiltInIdentifierAsName(Token token, ErrorCode errorCode) {
    if (token.type.isKeyword && token.keyword?.isPseudo != true) {
      errorReporter.reportErrorForToken(errorCode, token, [token.lexeme]);
    }
  }

  /// Verify that the given [switchCase] is terminated with 'break', 'continue',
  /// 'return' or 'throw'.
  ///
  /// see [CompileTimeErrorCode.CASE_BLOCK_NOT_TERMINATED].
  void _checkForCaseBlockNotTerminated(SwitchCase switchCase) {
    NodeList<Statement> statements = switchCase.statements;
    if (statements.isEmpty) {
      // fall-through without statements at all
      var parent = switchCase.parent;
      if (parent is SwitchStatement) {
        NodeList<SwitchMember> members = parent.members;
        int index = members.indexOf(switchCase);
        if (index != -1 && index < members.length - 1) {
          return;
        }
      }
      // no other switch member after this one
    } else {
      Statement statement = statements.last;
      if (statement is Block && statement.statements.isNotEmpty) {
        Block block = statement;
        statement = block.statements.last;
      }
      // terminated with statement
      if (statement is BreakStatement ||
          statement is ContinueStatement ||
          statement is ReturnStatement) {
        return;
      }
      // terminated with 'throw' expression
      if (statement is ExpressionStatement) {
        Expression expression = statement.expression;
        if (expression is ThrowExpression || expression is RethrowExpression) {
          return;
        }
      }
    }

    errorReporter.reportErrorForToken(
        CompileTimeErrorCode.CASE_BLOCK_NOT_TERMINATED, switchCase.keyword);
  }

  /// Verify that the switch cases in the given switch [statement] are
  /// terminated with 'break', 'continue', 'rethrow', 'return' or 'throw'.
  ///
  /// See [CompileTimeErrorCode.CASE_BLOCK_NOT_TERMINATED].
  void _checkForCaseBlocksNotTerminated(SwitchStatement statement) {
    if (_isNonNullableByDefault) return;

    NodeList<SwitchMember> members = statement.members;
    int lastMember = members.length - 1;
    for (int i = 0; i < lastMember; i++) {
      SwitchMember member = members[i];
      if (member is SwitchCase) {
        _checkForCaseBlockNotTerminated(member);
      }
    }
  }

  /// Verify that if a class is being mixed in and class modifiers are enabled
  /// in that class' library, then it must be a mixin class.
  ///
  /// See [CompileTimeErrorCode.CLASS_USED_AS_MIXIN].
  void _checkForClassUsedAsMixin(WithClause? withClause) {
    if (withClause != null) {
      for (NamedType withMixin in withClause.mixinTypes) {
        final withType = withMixin.type;
        if (withType is InterfaceType) {
          final withElement = withType.element;
          if (withElement is ClassElementImpl &&
              !withElement.isMixinClass &&
              withElement.library.featureSet
                  .isEnabled(Feature.class_modifiers) &&
              !_mayIgnoreClassModifiers(withElement.library)) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.CLASS_USED_AS_MIXIN,
                withMixin,
                [withElement.name]);
          }
        }
      }
    }
  }

  /// Verify that the [_enclosingClass] does not have a method and getter pair
  /// with the same name, via inheritance.
  ///
  /// See [CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE],
  /// [CompileTimeErrorCode.CONFLICTING_METHOD_AND_FIELD], and
  /// [CompileTimeErrorCode.CONFLICTING_FIELD_AND_METHOD].
  void _checkForConflictingClassMembers() {
    final enclosingClass = _enclosingClass;
    if (enclosingClass == null) {
      return;
    }

    Uri libraryUri = _currentLibrary.source.uri;
    final conflictingDeclaredNames = <String>{};

    // method declared in the enclosing class vs. inherited getter/setter
    for (MethodElement method in enclosingClass.methods) {
      String name = method.name;

      // find inherited property accessors
      final getter = _inheritanceManager.getInherited2(
          enclosingClass, Name(libraryUri, name));
      final setter = _inheritanceManager.getInherited2(
          enclosingClass, Name(libraryUri, '$name='));

      if (method.isStatic) {
        void reportStaticConflict(ExecutableElement inherited) {
          errorReporter.reportErrorForElement(
              CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, method, [
            enclosingClass.displayName,
            name,
            inherited.enclosingElement.displayName,
          ]);
        }

        if (getter != null) {
          reportStaticConflict(getter);
          continue;
        }

        if (setter != null) {
          reportStaticConflict(setter);
          continue;
        }
      }

      // Extension type methods preclude accessors.
      if (enclosingClass is ExtensionTypeElement) {
        continue;
      }

      void reportFieldConflict(PropertyAccessorElement inherited) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_METHOD_AND_FIELD, method, [
          enclosingClass.displayName,
          name,
          inherited.enclosingElement.displayName
        ]);
      }

      if (getter is PropertyAccessorElement) {
        reportFieldConflict(getter);
        continue;
      }

      if (setter is PropertyAccessorElement) {
        reportFieldConflict(setter);
        continue;
      }
    }

    // getter declared in the enclosing class vs. inherited method
    for (PropertyAccessorElement accessor in enclosingClass.accessors) {
      String name = accessor.displayName;

      // find inherited method or property accessor
      var inherited = _inheritanceManager.getInherited2(
          enclosingClass, Name(libraryUri, name));
      inherited ??= _inheritanceManager.getInherited2(
          enclosingClass, Name(libraryUri, '$name='));

      if (accessor.isStatic && inherited != null) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_STATIC_AND_INSTANCE, accessor, [
          enclosingClass.displayName,
          name,
          inherited.enclosingElement.displayName,
        ]);
        conflictingDeclaredNames.add(name);
      } else if (inherited is MethodElement) {
        // Extension type accessors preclude inherited accessors/methods.
        if (enclosingClass is ExtensionTypeElement) {
          continue;
        }
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_FIELD_AND_METHOD, accessor, [
          enclosingClass.displayName,
          name,
          inherited.enclosingElement.displayName
        ]);
        conflictingDeclaredNames.add(name);
      }
    }

    // Inherited method and setter with the same name.
    final inherited = _inheritanceManager.getInheritedMap2(enclosingClass);
    for (final entry in inherited.entries) {
      final method = entry.value;
      if (method is MethodElement) {
        final methodName = entry.key;
        if (conflictingDeclaredNames.contains(methodName.name)) {
          continue;
        }
        final setterName = methodName.forSetter;
        final setter = inherited[setterName];
        if (setter is PropertyAccessorElement) {
          errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_INHERITED_METHOD_AND_SETTER,
            enclosingClass,
            [
              enclosingClass.kind.displayName,
              enclosingClass.displayName,
              methodName.name,
            ],
            [
              DiagnosticMessageImpl(
                filePath: method.source.fullName,
                message: formatList(
                  "The method is inherited from the {0} '{1}'.",
                  [
                    method.enclosingElement.kind.displayName,
                    method.enclosingElement.name,
                  ],
                ),
                offset: method.nameOffset,
                length: method.nameLength,
                url: null,
              ),
              DiagnosticMessageImpl(
                filePath: setter.source.fullName,
                message: formatList(
                  "The setter is inherited from the {0} '{1}'.",
                  [
                    setter.enclosingElement.kind.displayName,
                    setter.enclosingElement.name,
                  ],
                ),
                offset: setter.nameOffset,
                length: setter.nameLength,
                url: null,
              ),
            ],
          );
        }
      }
    }
  }

  /// Verify all conflicts between type variable and enclosing class.
  void _checkForConflictingClassTypeVariableErrorCodes() {
    var enclosingClass = _enclosingClass!;
    for (TypeParameterElement typeParameter in enclosingClass.typeParameters) {
      String name = typeParameter.name;
      // name is same as the name of the enclosing class
      if (enclosingClass.name == name) {
        var code = enclosingClass is MixinElement
            ? CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MIXIN
            : CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_CLASS;
        errorReporter.reportErrorForElement(code, typeParameter, [name]);
      }
      // check members
      if (enclosingClass.getNamedConstructor(name) != null ||
          enclosingClass.getMethod(name) != null ||
          enclosingClass.getGetter(name) != null ||
          enclosingClass.getSetter(name) != null) {
        var code = enclosingClass is MixinElement
            ? CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER_MIXIN
            : CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER_CLASS;
        errorReporter.reportErrorForElement(code, typeParameter, [name]);
      }
    }
  }

  void _checkForConflictingEnumTypeVariableErrorCodes(
    EnumElementImpl element,
  ) {
    for (var typeParameter in element.typeParameters) {
      var name = typeParameter.name;
      // name is same as the name of the enclosing enum
      if (element.name == name) {
        errorReporter.reportErrorForElement(
          CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_ENUM,
          typeParameter,
          [name],
        );
      }
      // check members
      if (element.getMethod(name) != null ||
          element.getGetter(name) != null ||
          element.getSetter(name) != null) {
        errorReporter.reportErrorForElement(
          CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER_ENUM,
          typeParameter,
          [name],
        );
      }
    }
  }

  void _checkForConflictingExtensionTypeTypeVariableErrorCodes(
    ExtensionTypeElementImpl element,
  ) {
    for (var typeParameter in element.typeParameters) {
      var name = typeParameter.name;
      // name is same as the name of the enclosing class
      if (element.name == name) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_EXTENSION_TYPE,
            typeParameter,
            [name]);
      }
      // check members
      if (element.getNamedConstructor(name) != null ||
          element.getMethod(name) != null ||
          element.getGetter(name) != null ||
          element.getSetter(name) != null) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode
                .CONFLICTING_TYPE_VARIABLE_AND_MEMBER_EXTENSION_TYPE,
            typeParameter,
            [name]);
      }
    }
  }

  /// Verify all conflicts between type variable and enclosing extension.
  ///
  /// See [CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_EXTENSION], and
  /// [CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_EXTENSION_MEMBER].
  void _checkForConflictingExtensionTypeVariableErrorCodes() {
    for (TypeParameterElement typeParameter
        in _enclosingExtension!.typeParameters) {
      String name = typeParameter.name;
      // name is same as the name of the enclosing class
      if (_enclosingExtension!.name == name) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_EXTENSION,
            typeParameter,
            [name]);
      }
      // check members
      if (_enclosingExtension!.getMethod(name) != null ||
          _enclosingExtension!.getGetter(name) != null ||
          _enclosingExtension!.getSetter(name) != null) {
        errorReporter.reportErrorForElement(
            CompileTimeErrorCode.CONFLICTING_TYPE_VARIABLE_AND_MEMBER_EXTENSION,
            typeParameter,
            [name]);
      }
    }
  }

  void _checkForConflictingGenerics(NamedCompilationUnitMember node) {
    var element = node.declaredElement as InterfaceElement;

    var analysisSession = _currentLibrary.session;
    var errors = analysisSession.classHierarchy.errors(element);

    for (var error in errors) {
      if (error is IncompatibleInterfacesClassHierarchyError) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.CONFLICTING_GENERIC_INTERFACES,
          node.name,
          [
            _enclosingClass!.kind.displayName,
            _enclosingClass!.name,
            error.first.getDisplayString(withNullability: true),
            error.second.getDisplayString(withNullability: true),
          ],
        );
      } else {
        throw UnimplementedError('${error.runtimeType}');
      }
    }
  }

  /// Check that the given constructor [declaration] has a valid combination of
  /// redirecting constructor invocation(s), super constructor invocation(s),
  /// field initializers, and assert initializers.
  void _checkForConflictingInitializerErrorCodes(
      ConstructorDeclaration declaration) {
    var enclosingClass = _enclosingClass;
    if (enclosingClass == null) {
      return;
    }
    // Count and check each redirecting initializer.
    var redirectingInitializerCount = 0;
    var superInitializerCount = 0;
    late SuperConstructorInvocation superInitializer;
    for (ConstructorInitializer initializer in declaration.initializers) {
      if (initializer is RedirectingConstructorInvocation) {
        if (redirectingInitializerCount > 0) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.MULTIPLE_REDIRECTING_CONSTRUCTOR_INVOCATIONS,
              initializer);
        }
        if (declaration.factoryKeyword == null) {
          RedirectingConstructorInvocation invocation = initializer;
          var redirectingElement = invocation.staticElement;
          if (redirectingElement == null) {
            String enclosingNamedType = enclosingClass.displayName;
            String constructorStrName = enclosingNamedType;
            if (invocation.constructorName != null) {
              constructorStrName += ".${invocation.constructorName!.name}";
            }
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.REDIRECT_GENERATIVE_TO_MISSING_CONSTRUCTOR,
                invocation,
                [constructorStrName, enclosingNamedType]);
          } else {
            if (redirectingElement.isFactory) {
              errorReporter.reportErrorForNode(
                  CompileTimeErrorCode
                      .REDIRECT_GENERATIVE_TO_NON_GENERATIVE_CONSTRUCTOR,
                  initializer);
            }
          }
        }
        // [declaration] is a redirecting constructor via a redirecting
        // initializer.
        _checkForRedirectToNonConstConstructor(
          declaration.declaredElement!,
          initializer.staticElement,
          initializer.constructorName ?? initializer.thisKeyword,
        );
        redirectingInitializerCount++;
      } else if (initializer is SuperConstructorInvocation) {
        if (enclosingClass is EnumElement) {
          errorReporter.reportErrorForToken(
            CompileTimeErrorCode.SUPER_IN_ENUM_CONSTRUCTOR,
            initializer.superKeyword,
          );
        } else if (superInitializerCount == 1) {
          // Only report the second (first illegal) superinitializer.
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.MULTIPLE_SUPER_INITIALIZERS, initializer);
        }
        superInitializer = initializer;
        superInitializerCount++;
      }
    }
    // Check for initializers which are illegal when alongside a redirecting
    // initializer.
    if (redirectingInitializerCount > 0) {
      for (ConstructorInitializer initializer in declaration.initializers) {
        if (initializer is SuperConstructorInvocation) {
          if (enclosingClass is! EnumElement) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.SUPER_IN_REDIRECTING_CONSTRUCTOR,
                initializer);
          }
        }
        if (initializer is ConstructorFieldInitializer) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.FIELD_INITIALIZER_REDIRECTING_CONSTRUCTOR,
              initializer);
        }
        if (initializer is AssertInitializer) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.ASSERT_IN_REDIRECTING_CONSTRUCTOR,
              initializer);
        }
      }
    }
    if (enclosingClass is! EnumElement &&
        redirectingInitializerCount == 0 &&
        superInitializerCount == 1 &&
        superInitializer != declaration.initializers.last) {
      var superNamedType = enclosingClass.supertype!.element.displayName;
      var constructorStrName = superNamedType;
      var constructorName = superInitializer.constructorName;
      if (constructorName != null) {
        constructorStrName += '.${constructorName.name}';
      }
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.SUPER_INVOCATION_NOT_LAST,
          superInitializer.superKeyword,
          [constructorStrName]);
    }
  }

  /// Verify that if the given [constructor] declaration is 'const' then there
  /// are no invocations of non-'const' super constructors, and that there are
  /// no instance variables mixed in.
  ///
  /// Return `true` if an error is reported here, and the caller should stop
  /// checking the constructor for constant-related errors.
  ///
  /// See [CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_NON_CONST_SUPER], and
  /// [CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_MIXIN_WITH_FIELD].
  bool _checkForConstConstructorWithNonConstSuper(
      ConstructorDeclaration constructor) {
    var enclosingClass = _enclosingClass;
    if (enclosingClass == null || !_enclosingExecutable.isConstConstructor) {
      return false;
    }

    // OK, const factory, checked elsewhere
    if (constructor.factoryKeyword != null) {
      return false;
    }

    // check for mixins
    var instanceFields = <FieldElement>[];
    for (var mixin in enclosingClass.mixins) {
      instanceFields.addAll(mixin.element.fields.where((field) {
        if (field.isStatic) {
          return false;
        }
        if (field.isSynthetic) {
          return false;
        }
        // From the abstract and external fields specification:
        // > An abstract instance variable declaration D is treated as an
        // > abstract getter declaration and possibly an abstract setter
        // > declaration. The setter is included if and only if D is non-final.
        if (field.isAbstract && field.isFinal) {
          return false;
        }
        return true;
      }));
    }
    if (instanceFields.length == 1) {
      var field = instanceFields.single;
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_MIXIN_WITH_FIELD,
          constructor.returnType,
          ["'${field.enclosingElement.name}.${field.name}'"]);
      return true;
    } else if (instanceFields.length > 1) {
      var fieldNames = instanceFields
          .map((field) => "'${field.enclosingElement.name}.${field.name}'")
          .join(', ');
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_MIXIN_WITH_FIELDS,
          constructor.returnType,
          [fieldNames]);
      return true;
    }

    // Enum(s) always call a const super-constructor.
    if (enclosingClass is EnumElement) {
      return false;
    }

    final element = constructor.declaredElement;
    if (element == null) {
      return false;
    }

    // Redirecting constructors are checked to be const elsewhere.
    if (element.redirectedConstructor != null) {
      return false;
    }

    final invokedSuper = element.superConstructor;
    if (invokedSuper == null || invokedSuper.isConst) {
      return false;
    }

    // Often there is an explicit `super()` invocation, report on it.
    final superInvocation = constructor.initializers
        .whereType<SuperConstructorInvocation>()
        .firstOrNull;
    final errorNode = superInvocation ?? constructor.returnType;

    errorReporter.reportErrorForNode(
      CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_NON_CONST_SUPER,
      errorNode,
      [element.enclosingElement.displayName],
    );
    return true;
  }

  /// Verify that if the given [constructor] declaration is 'const' then there
  /// are no non-final instance variable. The [constructorElement] is the
  /// constructor element.
  void _checkForConstConstructorWithNonFinalField(
      ConstructorDeclaration constructor,
      ConstructorElement constructorElement) {
    if (!_enclosingExecutable.isConstConstructor) {
      return;
    }
    if (!_enclosingExecutable.isGenerativeConstructor) {
      return;
    }
    // check if there is non-final field
    final classElement = constructorElement.enclosingElement;
    if (classElement is! ClassElement || !classElement.hasNonFinalField) {
      return;
    }
    errorReporter.reportErrorForName(
        CompileTimeErrorCode.CONST_CONSTRUCTOR_WITH_NON_FINAL_FIELD,
        constructor);
  }

  /// Verify that the given 'const' instance creation [expression] is not
  /// creating a deferred type. The [constructorName] is the constructor name,
  /// always non-`null`. The [namedType] is the name of the type defining the
  /// constructor, always non-`null`.
  ///
  /// See [CompileTimeErrorCode.CONST_DEFERRED_CLASS].
  void _checkForConstDeferredClass(InstanceCreationExpression expression,
      ConstructorName constructorName, NamedType namedType) {
    if (namedType.isDeferred) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.CONST_DEFERRED_CLASS, constructorName);
    }
  }

  /// Verify that the given throw [expression] is not enclosed in a 'const'
  /// constructor declaration.
  ///
  /// See [CompileTimeErrorCode.CONST_CONSTRUCTOR_THROWS_EXCEPTION].
  void _checkForConstEvalThrowsException(ThrowExpression expression) {
    if (_enclosingExecutable.isConstConstructor) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.CONST_CONSTRUCTOR_THROWS_EXCEPTION, expression);
    }
  }

  /// Verify that the given instance creation [expression] is not being invoked
  /// on an abstract class. The [namedType] is the [NamedType] of the
  /// [ConstructorName] from the [InstanceCreationExpression], this is the AST
  /// node that the error is attached to. The [type] is the type being
  /// constructed with this [InstanceCreationExpression].
  void _checkForConstOrNewWithAbstractClass(
      InstanceCreationExpression expression,
      NamedType namedType,
      InterfaceType type) {
    final element = type.element;
    if (element is ClassElement && element.isAbstract) {
      var element = expression.constructorName.staticElement;
      if (element != null && !element.isFactory) {
        bool isImplicit =
            (expression as InstanceCreationExpressionImpl).isImplicit;
        if (!isImplicit) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.INSTANTIATE_ABSTRACT_CLASS, namedType);
        } else {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.INSTANTIATE_ABSTRACT_CLASS, namedType);
        }
      }
    }
  }

  /// Verify that the given [expression] is not a mixin instantiation.
  void _checkForConstOrNewWithMixin(InstanceCreationExpression expression,
      NamedType namedType, InterfaceType type) {
    if (type.element is MixinElement) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.MIXIN_INSTANTIATE, namedType);
    }
  }

  /// Verify that the given 'const' instance creation [expression] is not being
  /// invoked on a constructor that is not 'const'.
  ///
  /// This method assumes that the instance creation was tested to be 'const'
  /// before being called.
  ///
  /// See [CompileTimeErrorCode.CONST_WITH_NON_CONST].
  void _checkForConstWithNonConst(InstanceCreationExpression expression) {
    var constructorElement = expression.constructorName.staticElement;
    if (constructorElement != null && !constructorElement.isConst) {
      if (expression.keyword != null) {
        errorReporter.reportErrorForToken(
            CompileTimeErrorCode.CONST_WITH_NON_CONST, expression.keyword!);
      } else {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.CONST_WITH_NON_CONST, expression);
      }
    }
  }

  /// Verify that if the given 'const' instance creation [expression] is being
  /// invoked on the resolved constructor. The [constructorName] is the
  /// constructor name, always non-`null`. The [namedType] is the name of the
  /// type defining the constructor, always non-`null`.
  ///
  /// This method assumes that the instance creation was tested to be 'const'
  /// before being called.
  ///
  /// See [CompileTimeErrorCode.CONST_WITH_UNDEFINED_CONSTRUCTOR], and
  /// [CompileTimeErrorCode.CONST_WITH_UNDEFINED_CONSTRUCTOR_DEFAULT].
  void _checkForConstWithUndefinedConstructor(
      InstanceCreationExpression expression,
      ConstructorName constructorName,
      NamedType namedType) {
    // OK if resolved
    if (constructorName.staticElement != null) {
      return;
    }
    // report as named or default constructor absence
    var name = constructorName.name;
    if (name != null) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.CONST_WITH_UNDEFINED_CONSTRUCTOR,
        name,
        [namedType.qualifiedName, name.name],
      );
    } else {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.CONST_WITH_UNDEFINED_CONSTRUCTOR_DEFAULT,
        constructorName,
        [namedType.qualifiedName],
      );
    }
  }

  void _checkForDeadNullCoalesce(TypeImpl lhsType, Expression rhs) {
    if (!_isNonNullableByDefault) return;

    if (typeSystem.isStrictlyNonNullable(lhsType)) {
      errorReporter.reportErrorForNode(
        StaticWarningCode.DEAD_NULL_AWARE_EXPRESSION,
        rhs,
      );
    }
  }

  /// Report a diagnostic if there are any extensions in the imported library
  /// that are not hidden.
  void _checkForDeferredImportOfExtensions(
      ImportDirective directive, LibraryImportElement importElement) {
    for (var element in importElement.namespace.definedNames.values) {
      if (element is ExtensionElement) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.DEFERRED_IMPORT_OF_EXTENSION,
          directive.uri,
        );
        return;
      }
    }
  }

  /// Verify that any deferred imports in the given compilation [unit] have a
  /// unique prefix.
  ///
  /// See [CompileTimeErrorCode.SHARED_DEFERRED_PREFIX].
  void _checkForDeferredPrefixCollisions(CompilationUnit unit) {
    NodeList<Directive> directives = unit.directives;
    int count = directives.length;
    if (count > 0) {
      Map<PrefixElement, List<ImportDirective>> prefixToDirectivesMap =
          HashMap<PrefixElement, List<ImportDirective>>();
      for (int i = 0; i < count; i++) {
        Directive directive = directives[i];
        if (directive is ImportDirective) {
          var prefix = directive.prefix;
          if (prefix != null) {
            var element = prefix.staticElement;
            if (element is PrefixElement) {
              var elements = prefixToDirectivesMap[element];
              if (elements == null) {
                elements = <ImportDirective>[];
                prefixToDirectivesMap[element] = elements;
              }
              elements.add(directive);
            }
          }
        }
      }
      for (List<ImportDirective> imports in prefixToDirectivesMap.values) {
        _checkDeferredPrefixCollision(imports);
      }
    }
  }

  /// Return `true` if the caller should continue checking the rest of the
  /// information in the for-each part.
  bool _checkForEachParts(ForEachParts node, Element? variableElement) {
    if (checkForUseOfVoidResult(node.iterable)) {
      return false;
    }

    DartType iterableType = node.iterable.typeOrThrow;

    Token? awaitKeyword;
    var parent = node.parent;
    if (parent is ForStatement) {
      awaitKeyword = parent.awaitKeyword;
    } else if (parent is ForElement) {
      awaitKeyword = parent.awaitKeyword;
    }

    // Use an explicit string instead of [loopType] to remove the "<E>".
    String loopNamedType = awaitKeyword != null ? 'Stream' : 'Iterable';

    if (iterableType is DynamicType && strictCasts) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.FOR_IN_OF_INVALID_TYPE,
        node.iterable,
        [iterableType, loopNamedType],
      );
      return false;
    }

    // TODO(scheglov): use NullableDereferenceVerifier
    if (_isNonNullableByDefault) {
      if (typeSystem.isNullable(iterableType)) {
        return false;
      }
    }

    // The type of the loop variable.
    DartType variableType;
    if (variableElement is VariableElement) {
      variableType = variableElement.type;
    } else {
      return false;
    }

    // The object being iterated has to implement Iterable<T> for some T that
    // is assignable to the variable's type.
    // TODO(rnystrom): Move this into mostSpecificTypeArgument()?
    iterableType = typeSystem.resolveToBound(iterableType);

    var requiredSequenceType = awaitKeyword != null
        ? _typeProvider.streamDynamicType
        : _typeProvider.iterableDynamicType;

    if (typeSystem.isTop(iterableType)) {
      iterableType = requiredSequenceType;
    }

    if (!typeSystem.isAssignableTo(iterableType, requiredSequenceType,
        strictCasts: strictCasts)) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.FOR_IN_OF_INVALID_TYPE,
        node.iterable,
        [iterableType, loopNamedType],
      );
      return false;
    }

    DartType? sequenceElementType;
    {
      var sequenceElement = awaitKeyword != null
          ? _typeProvider.streamElement
          : _typeProvider.iterableElement;
      var sequenceType = iterableType.asInstanceOf(sequenceElement);
      if (sequenceType != null) {
        sequenceElementType = sequenceType.typeArguments[0];
      }
    }

    if (sequenceElementType == null) {
      return true;
    }

    if (!typeSystem.isAssignableTo(sequenceElementType, variableType,
        strictCasts: strictCasts)) {
      // Use an explicit string instead of [loopType] to remove the "<E>".
      String loopNamedType = awaitKeyword != null ? 'Stream' : 'Iterable';

      // A for-in loop is specified to desugar to a different set of statements
      // which include an assignment of the sequence element's `iterator`'s
      // `current` value, at which point "implicit tear-off conversion" may be
      // performed. We do not perform this desugaring; instead we allow a
      // special assignability here.
      var implicitCallMethod = getImplicitCallMethod(
          sequenceElementType, variableType, node.iterable);
      if (implicitCallMethod == null) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.FOR_IN_OF_INVALID_ELEMENT_TYPE,
          node.iterable,
          [iterableType, loopNamedType, variableType],
        );
      } else {
        var tearoffType = implicitCallMethod.type;
        // An implicit tear-off conversion does occur on the values of the
        // iterator, but this does not guarantee their assignability.

        if (_featureSet?.isEnabled(Feature.constructor_tearoffs) ?? true) {
          var typeArguments = typeSystem.inferFunctionTypeInstantiation(
            variableType as FunctionType,
            tearoffType,
            errorReporter: errorReporter,
            errorNode: node.iterable,
            genericMetadataIsEnabled: true,
            strictInference: options.strictInference,
            strictCasts: options.strictCasts,
            typeSystemOperations: typeSystemOperations,
          );
          if (typeArguments.isNotEmpty) {
            tearoffType = tearoffType.instantiate(typeArguments);
          }
        }

        if (!typeSystem.isAssignableTo(tearoffType, variableType,
            strictCasts: strictCasts)) {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.FOR_IN_OF_INVALID_ELEMENT_TYPE,
            node.iterable,
            [iterableType, loopNamedType, variableType],
          );
        }
      }
    }

    return true;
  }

  void _checkForEnumInstantiatedToBoundsIsNotWellBounded(
    EnumDeclaration node,
    EnumElementImpl element,
  ) {
    var valuesFieldType = element.valuesField?.type;
    if (valuesFieldType is InterfaceType) {
      var isWellBounded = typeSystem.isWellBounded(
        valuesFieldType.typeArguments.single,
        allowSuperBounded: true,
      );
      if (isWellBounded is NotWellBoundedTypeResult) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.ENUM_INSTANTIATED_TO_BOUNDS_IS_NOT_WELL_BOUNDED,
          node.name,
        );
      }
    }
  }

  /// Check that if the visiting library is not system, then any given library
  /// should not be SDK internal library. The [exportElement] is the
  /// [LibraryExportElement] retrieved from the node, if the element in the node was
  /// `null`, then this method is not called.
  ///
  /// See [CompileTimeErrorCode.EXPORT_INTERNAL_LIBRARY].
  void _checkForExportInternalLibrary(
      ExportDirective directive, LibraryExportElement exportElement) {
    if (_isInSystemLibrary) {
      return;
    }

    var exportedLibrary = exportElement.exportedLibrary;
    if (exportedLibrary == null) {
      return;
    }

    // should be private
    var sdk = _currentLibrary.context.sourceFactory.dartSdk!;
    var uri = exportedLibrary.source.uri.toString();
    var sdkLibrary = sdk.getSdkLibrary(uri);
    if (sdkLibrary == null) {
      return;
    }
    if (!sdkLibrary.isInternal) {
      return;
    }

    // It is safe to assume that `directive.uri.stringValue` is non-`null`,
    // because the only time it is `null` is if the URI contains a string
    // interpolation, in which case the export would never have resolved in the
    // first place.
    errorReporter.reportErrorForNode(
        CompileTimeErrorCode.EXPORT_INTERNAL_LIBRARY,
        directive,
        [directive.uri.stringValue!]);
  }

  /// See [CompileTimeErrorCode.EXPORT_LEGACY_SYMBOL].
  void _checkForExportLegacySymbol(ExportDirective node) {
    if (!_isNonNullableByDefault) {
      return;
    }

    var element = node.element!;
    // TODO(scheglov): Expose from ExportElement.
    var namespace =
        NamespaceBuilder().createExportNamespaceForDirective(element);

    for (var element in namespace.definedNames.values) {
      if (element == DynamicElementImpl.instance ||
          element == NeverElementImpl.instance) {
        continue;
      }
      if (!element.library!.isNonNullableByDefault) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.EXPORT_LEGACY_SYMBOL,
          node.uri,
          [element.displayName],
        );
        // Stop after the first symbol.
        // We don't want to list them all.
        break;
      }
    }
  }

  /// Verify that the given extends [clause] does not extend a deferred class.
  ///
  /// See [CompileTimeErrorCode.EXTENDS_DEFERRED_CLASS].
  void _checkForExtendsDeferredClass(NamedType? superclass) {
    if (superclass == null) {
      return;
    }
    _checkForExtendsOrImplementsDeferredClass(
        superclass, CompileTimeErrorCode.EXTENDS_DEFERRED_CLASS);
  }

  /// Verify that the given extends [clause] does not extend classes such as
  /// 'num' or 'String'.
  ///
  /// See [CompileTimeErrorCode.EXTENDS_DISALLOWED_CLASS].
  bool _checkForExtendsDisallowedClass(NamedType? superclass) {
    if (superclass == null) {
      return false;
    }
    return _checkForExtendsOrImplementsDisallowedClass(
        superclass, CompileTimeErrorCode.EXTENDS_DISALLOWED_CLASS);
  }

  /// Verify that the given [namedType] does not extend, implement or mixin
  /// classes that are deferred.
  ///
  /// See [_checkForExtendsDeferredClass],
  /// [_checkForExtendsDeferredClassInTypeAlias],
  /// [_checkForImplementsDeferredClass],
  /// [_checkForAllMixinErrorCodes],
  /// [CompileTimeErrorCode.EXTENDS_DEFERRED_CLASS],
  /// [CompileTimeErrorCode.IMPLEMENTS_DEFERRED_CLASS], and
  /// [CompileTimeErrorCode.MIXIN_DEFERRED_CLASS].
  bool _checkForExtendsOrImplementsDeferredClass(
      NamedType namedType, ErrorCode errorCode) {
    if (namedType.isSynthetic) {
      return false;
    }
    if (namedType.isDeferred) {
      errorReporter.reportErrorForNode(errorCode, namedType);
      return true;
    }
    return false;
  }

  /// Verify that the given [namedType] does not extend, implement or mixin
  /// classes such as 'num' or 'String'.
  ///
  // TODO(scheglov): Remove this method, when all inheritance / override
  // is concentrated. We keep it for now only because we need to know when
  // inheritance is completely wrong, so that we don't need to check anything
  // else.
  bool _checkForExtendsOrImplementsDisallowedClass(
      NamedType namedType, ErrorCode errorCode) {
    if (namedType.isSynthetic) {
      return false;
    }
    // The SDK implementation may implement disallowed types. For example,
    // JSNumber in dart2js and _Smi in Dart VM both implement int.
    if (_currentLibrary.source.uri.isScheme('dart')) {
      return false;
    }
    var type = namedType.type;
    return type is InterfaceType &&
        _typeProvider.isNonSubtypableClass(type.element);
  }

  void _checkForExtensionDeclaresMemberOfObject(MethodDeclaration node) {
    if (_enclosingExtension != null) {
      if (node.hasObjectMemberName) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.EXTENSION_DECLARES_MEMBER_OF_OBJECT,
          node.name,
        );
      }
    }

    if (_enclosingClass is ExtensionTypeElement) {
      if (node.hasObjectMemberName) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.EXTENSION_TYPE_DECLARES_MEMBER_OF_OBJECT,
          node.name,
        );
      }
    }
  }

  void _checkForExtensionTypeConstructorWithSuperInvocation(
    SuperConstructorInvocation node,
  ) {
    if (_enclosingClass is ExtensionTypeElement) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.EXTENSION_TYPE_CONSTRUCTOR_WITH_SUPER_INVOCATION,
        node.superKeyword,
      );
    }
  }

  void _checkForExtensionTypeDeclaresInstanceField(FieldDeclaration node) {
    if (_enclosingClass is! ExtensionTypeElement) {
      return;
    }

    if (node.isStatic || node.externalKeyword != null) {
      return;
    }

    for (final field in node.fields.variables) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.EXTENSION_TYPE_DECLARES_INSTANCE_FIELD,
        field.name,
      );
    }
  }

  void _checkForExtensionTypeImplementsDeferred(
    ExtensionTypeDeclarationImpl node,
  ) {
    final clause = node.implementsClause;
    if (clause == null) {
      return;
    }

    for (final type in clause.interfaces) {
      _checkForExtendsOrImplementsDeferredClass(
        type,
        CompileTimeErrorCode.IMPLEMENTS_DEFERRED_CLASS,
      );
    }
  }

  void _checkForExtensionTypeImplementsItself(
    ExtensionTypeDeclarationImpl node,
    ExtensionTypeElementImpl element,
  ) {
    if (element.hasImplementsSelfReference) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.EXTENSION_TYPE_IMPLEMENTS_ITSELF,
        node.name,
      );
    }
  }

  void _checkForExtensionTypeMemberConflicts({
    required ExtensionTypeDeclaration node,
    required ExtensionTypeElement element,
  }) {
    void report(String memberName, List<ExecutableElement> candidates) {
      final contextMessages = candidates.map<DiagnosticMessage>((executable) {
        final container = executable.enclosingElement as InterfaceElement;
        return DiagnosticMessageImpl(
          filePath: executable.source.fullName,
          offset: executable.nameOffset,
          length: executable.nameLength,
          message: "Inherited from '${container.name}'",
          url: null,
        );
      }).toList();
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.EXTENSION_TYPE_INHERITED_MEMBER_CONFLICT,
        node.name,
        [node.name.lexeme, memberName],
        contextMessages,
      );
    }

    final interface = _inheritanceManager.getInterface(element);
    for (final conflict in interface.conflicts) {
      switch (conflict) {
        case CandidatesConflict _:
          report(conflict.name.name, conflict.candidates);
        case HasNonExtensionAndExtensionMemberConflict _:
          report(conflict.name.name, [
            ...conflict.nonExtension,
            ...conflict.extension,
          ]);
        case NotUniqueExtensionMemberConflict _:
          report(conflict.name.name, conflict.candidates);
      }
    }
  }

  void _checkForExtensionTypeRepresentationDependsOnItself(
    ExtensionTypeDeclarationImpl node,
    ExtensionTypeElementImpl element,
  ) {
    if (element.hasRepresentationSelfReference) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.EXTENSION_TYPE_REPRESENTATION_DEPENDS_ON_ITSELF,
        node.name,
      );
    }
  }

  void _checkForExtensionTypeRepresentationTypeBottom(
    ExtensionTypeDeclarationImpl node,
    ExtensionTypeElementImpl element,
  ) {
    final representationType = element.representation.type;
    if (typeSystem.isBottom(representationType)) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.EXTENSION_TYPE_REPRESENTATION_TYPE_BOTTOM,
        node.representation.fieldType,
      );
    }
  }

  void _checkForExtensionTypeWithAbstractMember(
    ExtensionTypeDeclarationImpl node,
  ) {
    for (final member in node.members) {
      if (member is MethodDeclarationImpl && !member.isStatic) {
        if (member.isAbstract) {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.EXTENSION_TYPE_WITH_ABSTRACT_MEMBER,
            member,
            [member.name.lexeme, node.name.lexeme],
          );
        }
      }
    }
  }

  /// Verify that the given field formal [parameter] is in a constructor
  /// declaration.
  ///
  /// See [CompileTimeErrorCode.FIELD_INITIALIZER_OUTSIDE_CONSTRUCTOR].
  void _checkForFieldInitializingFormalRedirectingConstructor(
      FieldFormalParameter parameter) {
    // prepare the node that should be a ConstructorDeclaration
    var formalParameterList = parameter.parent;
    if (formalParameterList is! FormalParameterList) {
      formalParameterList = formalParameterList?.parent;
    }
    var constructor = formalParameterList?.parent;
    // now check whether the node is actually a ConstructorDeclaration
    if (constructor is ConstructorDeclaration) {
      // constructor cannot be a factory
      if (constructor.factoryKeyword != null) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.FIELD_INITIALIZER_FACTORY_CONSTRUCTOR,
            parameter);
        return;
      }
      // constructor cannot have a redirection
      for (ConstructorInitializer initializer in constructor.initializers) {
        if (initializer is RedirectingConstructorInvocation) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.FIELD_INITIALIZER_REDIRECTING_CONSTRUCTOR,
              parameter);
          return;
        }
      }
    } else {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.FIELD_INITIALIZER_OUTSIDE_CONSTRUCTOR,
          parameter);
    }
  }

  /// Verify that the given variable declaration [list] has only initialized
  /// variables if the list is final or const.
  ///
  /// See [CompileTimeErrorCode.CONST_NOT_INITIALIZED], and
  /// [CompileTimeErrorCode.FINAL_NOT_INITIALIZED].
  void _checkForFinalNotInitialized(VariableDeclarationList list) {
    if (_isInNativeClass || list.isSynthetic) {
      return;
    }

    // Handled during resolution, with flow analysis.
    if (_isNonNullableByDefault &&
        list.isFinal &&
        list.parent is VariableDeclarationStatement) {
      return;
    }

    bool isConst = list.isConst;
    if (!(isConst || list.isFinal)) {
      return;
    }
    NodeList<VariableDeclaration> variables = list.variables;
    for (VariableDeclaration variable in variables) {
      if (variable.initializer == null) {
        if (isConst) {
          errorReporter.reportErrorForToken(
              CompileTimeErrorCode.CONST_NOT_INITIALIZED,
              variable.name,
              [variable.name.lexeme]);
        } else {
          var variableElement = variable.declaredElement;
          if (variableElement is FieldElement &&
              (variableElement.isAbstract || variableElement.isExternal)) {
            // Abstract and external fields can't be initialized, so no error.
          } else if (variableElement is TopLevelVariableElement &&
              variableElement.isExternal) {
            // External top level variables can't be initialized, so no error.
          } else if (!_isNonNullableByDefault || !variable.isLate) {
            errorReporter.reportErrorForToken(
                CompileTimeErrorCode.FINAL_NOT_INITIALIZED,
                variable.name,
                [variable.name.lexeme]);
          }
        }
      }
    }
  }

  /// If there are no constructors in the given [members], verify that all
  /// final fields are initialized.  Cases in which there is at least one
  /// constructor are handled in [_checkForAllFinalInitializedErrorCodes].
  ///
  /// See [CompileTimeErrorCode.CONST_NOT_INITIALIZED], and
  /// [CompileTimeErrorCode.FINAL_NOT_INITIALIZED].
  void _checkForFinalNotInitializedInClass(List<ClassMember> members) {
    for (ClassMember classMember in members) {
      if (classMember is ConstructorDeclaration) {
        if (_isNonNullableByDefault) {
          if (classMember.factoryKeyword == null) {
            return;
          }
        } else {
          return;
        }
      }
    }
    for (ClassMember classMember in members) {
      if (classMember is FieldDeclaration) {
        var fields = classMember.fields;
        _checkForFinalNotInitialized(fields);
        _checkForNotInitializedNonNullableInstanceFields(classMember);
      }
    }
  }

  /// Check that if a direct supertype of a node is final, then it must be in
  /// the same library.
  ///
  /// See [CompileTimeErrorCode.FINAL_CLASS_EXTENDED_OUTSIDE_OF_LIBRARY],
  /// [CompileTimeErrorCode.FINAL_CLASS_IMPLEMENTED_OUTSIDE_OF_LIBRARY],
  /// [CompileTimeErrorCode.
  /// FINAL_CLASS_USED_AS_MIXIN_CONSTRAINT_OUTSIDE_OF_LIBRARY].
  void _checkForFinalSupertypeOutsideOfLibrary(
    NamedType? superclass,
    WithClause? withClause,
    ImplementsClause? implementsClause,
    OnClause? onClause,
  ) {
    if (superclass != null) {
      final type = superclass.type;
      if (type is InterfaceType) {
        final element = type.element;
        if (element is ClassElementImpl &&
            element.isFinal &&
            !element.isSealed &&
            element.library != _currentLibrary &&
            !_mayIgnoreClassModifiers(element.library)) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.FINAL_CLASS_EXTENDED_OUTSIDE_OF_LIBRARY,
              superclass,
              [element.name]);
        }
      }
    }
    if (implementsClause != null) {
      for (NamedType namedType in implementsClause.interfaces) {
        final type = namedType.type;
        if (type is InterfaceType) {
          final implementedInterfaces = [
            type,
            ...type.element.allSupertypes,
          ].map((e) => e.element).toList();
          for (final element in implementedInterfaces) {
            if (element is ClassElement &&
                element.isFinal &&
                !element.isSealed &&
                element.library != _currentLibrary &&
                !_mayIgnoreClassModifiers(element.library)) {
              // If the final interface is an indirect interface and is in a
              // different library that has class modifiers enabled, there is a
              // nearer declaration that would emit an error, if any.
              if (element != type.element &&
                  type.element.library.featureSet
                      .isEnabled(Feature.class_modifiers)) {
                continue;
              }

              errorReporter.reportErrorForNode(
                  CompileTimeErrorCode
                      .FINAL_CLASS_IMPLEMENTED_OUTSIDE_OF_LIBRARY,
                  namedType,
                  [element.name]);
              break;
            }
          }
        }
      }
    }
    if (onClause != null) {
      for (NamedType namedType in onClause.superclassConstraints) {
        final type = namedType.type;
        if (type is InterfaceType) {
          final element = type.element;
          if (element is ClassElement &&
              element.isFinal &&
              !element.isSealed &&
              element.library != _currentLibrary &&
              !_mayIgnoreClassModifiers(element.library)) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode
                    .FINAL_CLASS_USED_AS_MIXIN_CONSTRAINT_OUTSIDE_OF_LIBRARY,
                namedType,
                [element.name]);
          }
        }
      }
    }
  }

  void _checkForGenericFunctionType(TypeAnnotation? node) {
    if (node == null) {
      return;
    }
    if (_featureSet?.isEnabled(Feature.generic_metadata) ?? false) {
      return;
    }
    DartType type = node.typeOrThrow;
    if (type is FunctionType && type.typeFormals.isNotEmpty) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.GENERIC_FUNCTION_TYPE_CANNOT_BE_BOUND, node);
    }
  }

  void _checkForIllegalLanguageOverride(CompilationUnit node) {
    var sourceLanguageConstraint = options.sourceLanguageConstraint;
    if (sourceLanguageConstraint == null) {
      return;
    }

    var languageVersion = _currentLibrary.languageVersion.effective;
    if (sourceLanguageConstraint.allows(languageVersion)) {
      return;
    }

    var languageVersionToken = node.languageVersionToken;
    if (languageVersionToken != null) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.ILLEGAL_LANGUAGE_VERSION_OVERRIDE,
        languageVersionToken,
        ['$sourceLanguageConstraint'],
      );
    }
  }

  /// Verify that the given implements [clause] does not implement classes such
  /// as 'num' or 'String'.
  ///
  /// See [CompileTimeErrorCode.IMPLEMENTS_DISALLOWED_CLASS],
  /// [CompileTimeErrorCode.IMPLEMENTS_DEFERRED_CLASS].
  bool _checkForImplementsClauseErrorCodes(ImplementsClause? clause) {
    if (clause == null) {
      return false;
    }
    bool foundError = false;
    for (NamedType type in clause.interfaces) {
      if (_checkForExtendsOrImplementsDisallowedClass(
          type, CompileTimeErrorCode.IMPLEMENTS_DISALLOWED_CLASS)) {
        foundError = true;
      } else if (_checkForExtendsOrImplementsDeferredClass(
          type, CompileTimeErrorCode.IMPLEMENTS_DEFERRED_CLASS)) {
        foundError = true;
      }
    }
    return foundError;
  }

  /// Check that if the visiting library is not system, then any given library
  /// should not be SDK internal library. The [importElement] is the
  /// [LibraryImportElement] retrieved from the node, if the element in the node
  /// was `null`, then this method is not called.
  void _checkForImportInternalLibrary(
      ImportDirective directive, LibraryImportElement importElement) {
    if (_isInSystemLibrary || _isWasm(importElement)) {
      return;
    }

    var importedLibrary = importElement.importedLibrary;
    if (importedLibrary == null) {
      return;
    }

    // should be private
    var sdk = _currentLibrary.context.sourceFactory.dartSdk!;
    var uri = importedLibrary.source.uri.toString();
    var sdkLibrary = sdk.getSdkLibrary(uri);
    if (sdkLibrary == null || !sdkLibrary.isInternal) {
      return;
    }
    // The only way an import URI's `stringValue` can be `null` is if the string
    // contained interpolations, in which case the import would have failed to
    // resolve, and we would never reach here.  So it is safe to assume that
    // `directive.uri.stringValue` is non-`null`.
    errorReporter.reportErrorForNode(
        CompileTimeErrorCode.IMPORT_INTERNAL_LIBRARY,
        directive.uri,
        [directive.uri.stringValue!]);
  }

  /// Check that the given [typeReference] is not a type reference and that then
  /// the [name] is reference to an instance member.
  ///
  /// See [CompileTimeErrorCode.INSTANCE_ACCESS_TO_STATIC_MEMBER].
  void _checkForInstanceAccessToStaticMember(InterfaceElement? typeReference,
      Expression? target, SimpleIdentifier name) {
    if (_isInComment) {
      // OK, in comment
      return;
    }
    // prepare member Element
    var element = name.writeOrReadElement;
    if (element is ExecutableElement) {
      if (!element.isStatic) {
        // OK, instance member
        return;
      }
      Element enclosingElement = element.enclosingElement;
      if (enclosingElement is ExtensionElement) {
        if (target is ExtensionOverride) {
          // OK, target is an extension override
          return;
        } else if (target is SimpleIdentifier &&
            target.staticElement is ExtensionElement) {
          return;
        } else if (target is PrefixedIdentifier &&
            target.staticElement is ExtensionElement) {
          return;
        }
      } else {
        if (typeReference != null) {
          // OK, target is a type
          return;
        }
        if (enclosingElement is! InterfaceElement) {
          // OK, top-level element
          return;
        }
      }
    }
  }

  /// Verify that if a class is extending an interface class or mixing in an
  /// interface mixin, it must be within the same library as that class or
  /// mixin.
  ///
  /// See
  /// [CompileTimeErrorCode.INTERFACE_CLASS_EXTENDED_OUTSIDE_OF_LIBRARY].
  void _checkForInterfaceClassOrMixinSuperclassOutsideOfLibrary(
      NamedType? superclass, WithClause? withClause) {
    if (superclass != null) {
      final superclassType = superclass.type;
      if (superclassType is InterfaceType) {
        final superclassElement = superclassType.element;
        if (superclassElement is ClassElementImpl &&
            superclassElement.isInterface &&
            !superclassElement.isSealed &&
            superclassElement.library != _currentLibrary &&
            !_mayIgnoreClassModifiers(superclassElement.library)) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.INTERFACE_CLASS_EXTENDED_OUTSIDE_OF_LIBRARY,
              superclass,
              [superclassElement.name]);
        }
      }
    }
  }

  /// Verify that an 'int' can be assigned to the parameter corresponding to the
  /// given [argument]. This is used for prefix and postfix expressions where
  /// the argument value is implicit.
  ///
  /// See [CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE].
  void _checkForIntNotAssignable(Expression argument) {
    var staticParameterElement = argument.staticParameterElement;
    var staticParameterType = staticParameterElement?.type;
    if (staticParameterType != null) {
      checkForArgumentTypeNotAssignable(argument, staticParameterType, _intType,
          CompileTimeErrorCode.ARGUMENT_TYPE_NOT_ASSIGNABLE);
    }
  }

  /// Verify that the given [annotation] isn't defined in a deferred library.
  ///
  /// See [CompileTimeErrorCode.INVALID_ANNOTATION_FROM_DEFERRED_LIBRARY].
  void _checkForInvalidAnnotationFromDeferredLibrary(Annotation annotation) {
    Identifier nameIdentifier = annotation.name;
    if (nameIdentifier is PrefixedIdentifier && nameIdentifier.isDeferred) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INVALID_ANNOTATION_FROM_DEFERRED_LIBRARY,
          annotation.name);
    }
  }

  /// Check the given [initializer] to ensure that the field being initialized
  /// is a valid field. The [fieldName] is the field name from the
  /// [ConstructorFieldInitializer]. The [staticElement] is the static element
  /// from the name in the [ConstructorFieldInitializer].
  void _checkForInvalidField(ConstructorFieldInitializer initializer,
      SimpleIdentifier fieldName, Element? staticElement) {
    if (staticElement is FieldElement) {
      if (staticElement.isSynthetic) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.INITIALIZER_FOR_NON_EXISTENT_FIELD,
            initializer,
            [fieldName.name]);
      } else if (staticElement.isStatic) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.INITIALIZER_FOR_STATIC_FIELD,
            initializer,
            [fieldName.name]);
      }
    } else {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INITIALIZER_FOR_NON_EXISTENT_FIELD,
          initializer,
          [fieldName.name]);
      return;
    }
  }

  void _checkForInvalidGenerativeConstructorReference(ConstructorName node) {
    var constructorElement = node.staticElement;
    if (constructorElement != null &&
        constructorElement.isGenerative &&
        constructorElement.enclosingElement is EnumElement) {
      if (_currentLibrary.featureSet.isEnabled(Feature.enhanced_enums)) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INVALID_REFERENCE_TO_GENERATIVE_ENUM_CONSTRUCTOR,
          node,
        );
      } else {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INSTANTIATE_ENUM,
          node.type,
        );
      }
    }
  }

  /// Verify that if the given [identifier] is part of a constructor
  /// initializer, then it does not implicitly reference 'this' expression.
  ///
  /// See [CompileTimeErrorCode.IMPLICIT_THIS_REFERENCE_IN_INITIALIZER],
  /// [CompileTimeErrorCode.INSTANCE_MEMBER_ACCESS_FROM_FACTORY], and
  /// [CompileTimeErrorCode.INSTANCE_MEMBER_ACCESS_FROM_STATIC].
  void _checkForInvalidInstanceMemberAccess(SimpleIdentifier identifier) {
    if (_isInComment) {
      return;
    }
    if (!_isInConstructorInitializer &&
        !_enclosingExecutable.inStaticMethod &&
        !_enclosingExecutable.inFactoryConstructor &&
        !_isInInstanceNotLateVariableDeclaration &&
        !_isInStaticVariableDeclaration) {
      return;
    }
    // prepare element
    var element = identifier.writeOrReadElement;
    if (!(element is MethodElement || element is PropertyAccessorElement)) {
      return;
    }
    // static element
    ExecutableElement executableElement = element as ExecutableElement;
    if (executableElement.isStatic) {
      return;
    }
    // not a class member
    Element enclosingElement = element.enclosingElement;
    if (enclosingElement is! InterfaceElement &&
        enclosingElement is! ExtensionElement) {
      return;
    }
    // qualified method invocation
    var parent = identifier.parent;
    if (parent is MethodInvocation) {
      if (identical(parent.methodName, identifier) &&
          parent.realTarget != null) {
        return;
      }
    }
    // qualified property access
    if (parent is PropertyAccess) {
      if (identical(parent.propertyName, identifier)) {
        return;
      }
    }
    if (parent is PrefixedIdentifier) {
      if (identical(parent.identifier, identifier)) {
        return;
      }
    }

    if (_enclosingExecutable.inStaticMethod) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INSTANCE_MEMBER_ACCESS_FROM_STATIC, identifier);
    } else if (_enclosingExecutable.inFactoryConstructor) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INSTANCE_MEMBER_ACCESS_FROM_FACTORY, identifier);
    } else {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.IMPLICIT_THIS_REFERENCE_IN_INITIALIZER,
          identifier,
          [identifier.name]);
    }
  }

  /// Check to see whether the given function [body] has a modifier associated
  /// with it, and report it as an error if it does.
  void _checkForInvalidModifierOnBody(
      FunctionBody body, CompileTimeErrorCode errorCode) {
    var keyword = body.keyword;
    if (keyword != null) {
      errorReporter.reportErrorForToken(errorCode, keyword, [keyword.lexeme]);
    }
  }

  /// Verify that the usage of the given 'this' is valid.
  ///
  /// See [CompileTimeErrorCode.INVALID_REFERENCE_TO_THIS].
  void _checkForInvalidReferenceToThis(ThisExpression expression) {
    if (!_thisAccessTracker.hasAccess) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.INVALID_REFERENCE_TO_THIS, expression);
    }
  }

  void _checkForLateFinalFieldWithConstConstructor(FieldDeclaration node) {
    if (node.isStatic) return;

    var variableList = node.fields;
    if (!variableList.isFinal) return;

    var lateKeyword = variableList.lateKeyword;
    if (lateKeyword == null) return;

    var enclosingClass = _enclosingClass;
    if (enclosingClass == null) {
      // The field is in an extension and should be handled elsewhere.
      return;
    }

    var hasGenerativeConstConstructor =
        _enclosingClass!.constructors.any((c) => c.isConst && !c.isFactory);
    if (!hasGenerativeConstConstructor) return;

    errorReporter.reportErrorForToken(
      CompileTimeErrorCode.LATE_FINAL_FIELD_WITH_CONST_CONSTRUCTOR,
      lateKeyword,
    );
  }

  /// Verify that the elements of the given list [literal] are subtypes of the
  /// list's static type.
  ///
  /// See [CompileTimeErrorCode.LIST_ELEMENT_TYPE_NOT_ASSIGNABLE].
  void _checkForListElementTypeNotAssignable(ListLiteral literal) {
    // Determine the list's element type. We base this on the static type and
    // not the literal's type arguments because in strong mode, the type
    // arguments may be inferred.
    DartType listType = literal.typeOrThrow;
    assert(listType is InterfaceTypeImpl);

    List<DartType> typeArguments =
        (listType as InterfaceTypeImpl).typeArguments;
    assert(typeArguments.length == 1);

    DartType listElementType = typeArguments[0];

    // Check every list element.
    var verifier = LiteralElementVerifier(
      _typeProvider,
      typeSystem,
      errorReporter,
      this,
      forList: true,
      elementType: listElementType,
      featureSet: _featureSet!,
    );
    for (CollectionElement element in literal.elements) {
      verifier.verify(element);
    }
  }

  void _checkForMainFunction1(Token nameToken, Element declaredElement) {
    if (!_currentLibrary.isNonNullableByDefault) {
      return;
    }

    // We should only check exported declarations, i.e. top-level.
    if (declaredElement.enclosingElement is! CompilationUnitElement) {
      return;
    }

    if (declaredElement.displayName != 'main') {
      return;
    }

    if (declaredElement is! FunctionElement) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.MAIN_IS_NOT_FUNCTION,
        nameToken,
      );
    }
  }

  void _checkForMainFunction2(FunctionDeclaration functionDeclaration) {
    if (!_currentLibrary.isNonNullableByDefault) {
      return;
    }

    if (functionDeclaration.name.lexeme != 'main') {
      return;
    }

    if (functionDeclaration.parent is! CompilationUnit) {
      return;
    }

    final parameterList = functionDeclaration.functionExpression.parameters;
    if (parameterList == null) {
      return;
    }

    var parameters = parameterList.parameters;
    var positional = parameters.where((e) => e.isPositional).toList();
    var requiredPositional =
        parameters.where((e) => e.isRequiredPositional).toList();

    if (requiredPositional.length > 2) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.MAIN_HAS_TOO_MANY_REQUIRED_POSITIONAL_PARAMETERS,
        functionDeclaration.name,
      );
    }

    if (parameters.any((e) => e.isRequiredNamed)) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.MAIN_HAS_REQUIRED_NAMED_PARAMETERS,
        functionDeclaration.name,
      );
    }

    if (positional.isNotEmpty) {
      var first = positional.first;
      var type = first.declaredElement!.type;
      var listOfString = _typeProvider.listType(_typeProvider.stringType);
      if (!typeSystem.isSubtypeOf(listOfString, type)) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.MAIN_FIRST_POSITIONAL_PARAMETER_TYPE,
          first.notDefault.typeOrSelf,
        );
      }
    }
  }

  void _checkForMapTypeNotAssignable(SetOrMapLiteral literal) {
    // Determine the map's key and value types. We base this on the static type
    // and not the literal's type arguments because in strong mode, the type
    // arguments may be inferred.
    DartType mapType = literal.typeOrThrow;
    assert(mapType is InterfaceTypeImpl);

    List<DartType> typeArguments = (mapType as InterfaceTypeImpl).typeArguments;
    // It is possible for the number of type arguments to be inconsistent when
    // the literal is ambiguous and a non-map type was selected.
    // TODO(brianwilkerson): Unify this and _checkForSetElementTypeNotAssignable3
    //  to better handle recovery situations.
    if (typeArguments.length == 2) {
      DartType keyType = typeArguments[0];
      DartType valueType = typeArguments[1];

      var verifier = LiteralElementVerifier(
        _typeProvider,
        typeSystem,
        errorReporter,
        this,
        forMap: true,
        mapKeyType: keyType,
        mapValueType: valueType,
        featureSet: _featureSet!,
      );
      for (CollectionElement element in literal.elements) {
        verifier.verify(element);
      }
    }
  }

  /// Check to make sure that the given switch [statement] whose static type is
  /// an enum type either have a default case or include all of the enum
  /// constants.
  void _checkForMissingEnumConstantInSwitch(SwitchStatement statement) {
    if (_currentLibrary.featureSet.isEnabled(Feature.patterns)) {
      // Exhaustiveness checking cover this warning.
      return;
    }

    // TODO(brianwilkerson): This needs to be checked after constant values have
    // been computed.
    var expressionType = statement.expression.staticType;

    var hasCaseNull = false;
    if (expressionType is InterfaceType) {
      var enumElement = expressionType.element;
      if (enumElement is EnumElement) {
        var constantNames = enumElement.fields
            .where((field) => field.isEnumConstant)
            .map((field) => field.name)
            .toSet();

        for (var member in statement.members) {
          Expression? caseConstant;
          if (member is SwitchCase) {
            caseConstant = member.expression;
          } else if (member is SwitchPatternCase) {
            var guardedPattern = member.guardedPattern;
            if (guardedPattern.whenClause == null) {
              var pattern = guardedPattern.pattern.unParenthesized;
              if (pattern is ConstantPattern) {
                caseConstant = pattern.expression;
              }
            }
          }
          if (caseConstant != null) {
            var expression = caseConstant.unParenthesized;
            if (expression is NullLiteral) {
              hasCaseNull = true;
            } else {
              var constantName = _getConstantName(expression);
              constantNames.remove(constantName);
            }
          }
          if (member is SwitchDefault) {
            return;
          }
        }

        for (var constantName in constantNames) {
          int offset = statement.offset;
          int end = statement.rightParenthesis.end;
          errorReporter.reportErrorForOffset(
            StaticWarningCode.MISSING_ENUM_CONSTANT_IN_SWITCH,
            offset,
            end - offset,
            [constantName],
          );
        }

        if (typeSystem.isNullable(expressionType) && !hasCaseNull) {
          int offset = statement.offset;
          int end = statement.rightParenthesis.end;
          errorReporter.reportErrorForOffset(
            StaticWarningCode.MISSING_ENUM_CONSTANT_IN_SWITCH,
            offset,
            end - offset,
            ['null'],
          );
        }
      }
    }
  }

  /// Verify that the given mixin does not have an explicitly declared
  /// constructor. The [mixinName] is the node to report problem on. The
  /// [mixinElement] is the mixing to evaluate.
  ///
  /// See [CompileTimeErrorCode.MIXIN_CLASS_DECLARES_CONSTRUCTOR].
  bool _checkForMixinClassDeclaresConstructor(
      NamedType mixinName, InterfaceElement mixinElement) {
    for (ConstructorElement constructor in mixinElement.constructors) {
      if (!constructor.isSynthetic && !constructor.isFactory) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.MIXIN_CLASS_DECLARES_CONSTRUCTOR,
            mixinName,
            [mixinElement.name]);
        return true;
      }
    }
    return false;
  }

  /// Verify that mixin classes must have 'Object' as their superclass and that
  /// they do not have a constructor.
  ///
  /// See [CompileTimeErrorCode.MIXIN_CLASS_DECLARES_CONSTRUCTOR],
  /// [CompileTimeErrorCode.MIXIN_INHERITS_FROM_NOT_OBJECT].
  void _checkForMixinClassErrorCodes(
      NamedCompilationUnitMember node,
      List<ClassMember> members,
      NamedType? superclass,
      WithClause? withClause) {
    final element = node.declaredElement;
    if (element is ClassElementImpl && element.isMixinClass) {
      // Check that the class does not have a constructor.
      for (ClassMember member in members) {
        if (member is ConstructorDeclarationImpl) {
          if (!member.isSynthetic && member.factoryKeyword == null) {
            // Report errors on non-trivial generative constructors on mixin
            // classes.
            if (!member.isTrivial) {
              errorReporter.reportErrorForNode(
                  CompileTimeErrorCode.MIXIN_CLASS_DECLARES_CONSTRUCTOR,
                  member.returnType,
                  [element.name]);
            }
          }
        }
      }
      // Check that the class has 'Object' as their superclass.
      if (superclass != null && !superclass.typeOrThrow.isDartCoreObject) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.MIXIN_CLASS_DECLARATION_EXTENDS_NOT_OBJECT,
          superclass,
          [element.name],
        );
      } else if (withClause != null &&
          !(element.isMixinApplication && withClause.mixinTypes.length < 2)) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.MIXIN_CLASS_DECLARATION_EXTENDS_NOT_OBJECT,
          withClause,
          [element.name],
        );
      }
    }
  }

  /// Verify that the given mixin has the 'Object' superclass.
  ///
  /// The [mixinName] is the node to report problem on. The [mixinElement] is
  /// the mixing to evaluate.
  ///
  /// See [CompileTimeErrorCode.MIXIN_INHERITS_FROM_NOT_OBJECT].
  bool _checkForMixinInheritsNotFromObject(
      NamedType mixinName, InterfaceElement mixinElement) {
    if (mixinElement is! ClassElement) {
      return false;
    }

    var mixinSupertype = mixinElement.supertype;
    if (mixinSupertype == null || mixinSupertype.isDartCoreObject) {
      var mixins = mixinElement.mixins;
      if (mixins.isEmpty ||
          mixinElement.isMixinApplication && mixins.length < 2) {
        return false;
      }
    }

    errorReporter.reportErrorForNode(
      CompileTimeErrorCode.MIXIN_INHERITS_FROM_NOT_OBJECT,
      mixinName,
      [mixinElement.name],
    );
    return true;
  }

  /// Check that superclass constrains for the mixin type of [mixinName] at
  /// the [mixinIndex] position in the mixins list are satisfied by the
  /// [_enclosingClass], or a previous mixin.
  bool _checkForMixinSuperclassConstraints(
      int mixinIndex, NamedType mixinName) {
    InterfaceType mixinType = mixinName.type as InterfaceType;
    for (var constraint in mixinType.superclassConstraints) {
      var superType = _enclosingClass!.supertype as InterfaceTypeImpl;
      if (_currentLibrary.isNonNullableByDefault) {
        superType = superType.withNullability(NullabilitySuffix.none);
      }

      bool isSatisfied = typeSystem.isSubtypeOf(superType, constraint);
      if (!isSatisfied) {
        for (int i = 0; i < mixinIndex && !isSatisfied; i++) {
          isSatisfied =
              typeSystem.isSubtypeOf(_enclosingClass!.mixins[i], constraint);
        }
      }
      if (!isSatisfied) {
        // This error can only occur if [mixinName] resolved to an actual mixin,
        // so we can safely rely on `mixinName.type` being non-`null`.
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.MIXIN_APPLICATION_NOT_IMPLEMENTED_INTERFACE,
          mixinName.name2,
          [
            mixinName.type!,
            superType,
            constraint,
          ],
        );
        return true;
      }
    }
    return false;
  }

  /// Check that the superclass of the given [mixinElement] at the given
  /// [mixinIndex] in the list of mixins of [_enclosingClass] has concrete
  /// implementations of all the super-invoked members of the [mixinElement].
  bool _checkForMixinSuperInvokedMembers(int mixinIndex, NamedType mixinName,
      InterfaceElement mixinElement, InterfaceType mixinType) {
    var mixinElementImpl = mixinElement as MixinElementImpl;
    if (mixinElementImpl.superInvokedNames.isEmpty) {
      return false;
    }

    Uri mixinLibraryUri = mixinElement.librarySource.uri;
    for (var name in mixinElementImpl.superInvokedNames) {
      var nameObject = Name(mixinLibraryUri, name);

      var superMember = _inheritanceManager.getMember2(
          _enclosingClass!, nameObject,
          forMixinIndex: mixinIndex, concrete: true, forSuper: true);

      if (superMember == null) {
        var isSetter = name.endsWith('=');

        var errorCode = isSetter
            ? CompileTimeErrorCode
                .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_SETTER
            : CompileTimeErrorCode
                .MIXIN_APPLICATION_NO_CONCRETE_SUPER_INVOKED_MEMBER;

        if (isSetter) {
          name = name.substring(0, name.length - 1);
        }

        errorReporter.reportErrorForNode(errorCode, mixinName, [name]);
        return true;
      }

      var mixinMember =
          _inheritanceManager.getMember(mixinType, nameObject, forSuper: true);

      if (mixinMember != null) {
        var isCorrect = CorrectOverrideHelper(
          library: _currentLibrary,
          thisMember: superMember,
        ).isCorrectOverrideOf(
          superMember: mixinMember,
        );
        if (!isCorrect) {
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode
                .MIXIN_APPLICATION_CONCRETE_SUPER_INVOKED_MEMBER_TYPE,
            mixinName,
            [name, mixinMember.type, superMember.type],
          );
          return true;
        }
      }
    }
    return false;
  }

  /// Check for the declaration of a mixin from a library other than the current
  /// library that defines a private member that conflicts with a private name
  /// from the same library but from a superclass or a different mixin.
  void _checkForMixinWithConflictingPrivateMember(
      WithClause? withClause, NamedType? superclassName) {
    if (withClause == null) {
      return;
    }
    var declaredSupertype = superclassName?.type ?? _typeProvider.objectType;
    if (declaredSupertype is! InterfaceType) {
      return;
    }
    Map<LibraryElement, Map<String, String>> mixedInNames =
        <LibraryElement, Map<String, String>>{};

    /// Report an error and return `true` if the given [name] is a private name
    /// (which is defined in the given [library]) and it conflicts with another
    /// definition of that name inherited from the superclass.
    bool isConflictingName(
        String name, LibraryElement library, NamedType namedType) {
      if (Identifier.isPrivateName(name)) {
        Map<String, String> names = mixedInNames.putIfAbsent(library, () => {});
        var conflictingName = names[name];
        if (conflictingName != null) {
          if (name.endsWith('=')) {
            name = name.substring(0, name.length - 1);
          }
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.PRIVATE_COLLISION_IN_MIXIN_APPLICATION,
            namedType,
            [name, namedType.name2.lexeme, conflictingName],
          );
          return true;
        }
        names[name] = namedType.name2.lexeme;
        var inheritedMember = _inheritanceManager.getMember2(
          declaredSupertype.element,
          Name(library.source.uri, name),
          concrete: true,
        );
        if (inheritedMember != null) {
          if (name.endsWith('=')) {
            name = name.substring(0, name.length - 1);
          }
          // Inherited members are always contained inside named elements, so we
          // can safely assume `inheritedMember.enclosingElement3.name` is
          // non-`null`.
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.PRIVATE_COLLISION_IN_MIXIN_APPLICATION,
              namedType, [
            name,
            namedType.name2.lexeme,
            inheritedMember.enclosingElement.name!
          ]);
          return true;
        }
      }
      return false;
    }

    for (NamedType mixinType in withClause.mixinTypes) {
      DartType type = mixinType.typeOrThrow;
      if (type is InterfaceType) {
        LibraryElement library = type.element.library;
        if (library != _currentLibrary) {
          for (PropertyAccessorElement accessor in type.accessors) {
            if (accessor.isStatic) {
              continue;
            }
            if (isConflictingName(accessor.name, library, mixinType)) {
              return;
            }
          }
          for (MethodElement method in type.methods) {
            if (method.isStatic) {
              continue;
            }
            if (isConflictingName(method.name, library, mixinType)) {
              return;
            }
          }
        }
      }
    }
  }

  /// Checks to ensure that the given native function [body] is in SDK code.
  ///
  /// See [ParserErrorCode.NATIVE_FUNCTION_BODY_IN_NON_SDK_CODE].
  void _checkForNativeFunctionBodyInNonSdkCode(NativeFunctionBody body) {
    if (!_isInSystemLibrary) {
      errorReporter.reportErrorForNode(
          ParserErrorCode.NATIVE_FUNCTION_BODY_IN_NON_SDK_CODE, body);
    }
  }

  /// Verify that the given instance creation [expression] invokes an existing
  /// constructor. The [constructorName] is the constructor name.
  /// The [namedType] is the name of the type defining the constructor.
  ///
  /// This method assumes that the instance creation was tested to be 'new'
  /// before being called.
  ///
  /// See [CompileTimeErrorCode.NEW_WITH_UNDEFINED_CONSTRUCTOR].
  void _checkForNewWithUndefinedConstructor(
      InstanceCreationExpression expression,
      ConstructorName constructorName,
      NamedType namedType) {
    // OK if resolved
    if (constructorName.staticElement != null) {
      return;
    }
    DartType type = namedType.typeOrThrow;
    if (type is InterfaceType) {
      final element = type.element;
      if (element is EnumElement || element is MixinElement) {
        // We have already reported the error.
        return;
      }
    }
    // report as named or default constructor absence
    var name = constructorName.name;
    if (name != null) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.NEW_WITH_UNDEFINED_CONSTRUCTOR,
        name,
        [namedType.qualifiedName, name.name],
      );
    } else {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.NEW_WITH_UNDEFINED_CONSTRUCTOR_DEFAULT,
        constructorName,
        [namedType.qualifiedName],
      );
    }
  }

  /// Check that if the given class [declaration] implicitly calls default
  /// constructor of its superclass, there should be such default constructor -
  /// implicit or explicit.
  ///
  /// See [CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_IMPLICIT].
  void _checkForNoDefaultSuperConstructorImplicit(
      ClassDeclaration declaration) {
    // do nothing if there is explicit constructor
    List<ConstructorElement> constructors = _enclosingClass!.constructors;
    if (!constructors[0].isSynthetic) {
      return;
    }
    // prepare super
    var superType = _enclosingClass!.supertype;
    if (superType == null) {
      return;
    }
    final superElement = superType.element;
    // try to find default generative super constructor
    var superUnnamedConstructor = superElement.unnamedConstructor;
    superUnnamedConstructor = superUnnamedConstructor != null
        ? _currentLibrary.toLegacyElementIfOptOut(superUnnamedConstructor)
        : superUnnamedConstructor;
    if (superUnnamedConstructor != null) {
      if (superUnnamedConstructor.isFactory) {
        errorReporter.reportErrorForToken(
            CompileTimeErrorCode.NON_GENERATIVE_IMPLICIT_CONSTRUCTOR,
            declaration.name, [
          superElement.name,
          _enclosingClass!.name,
          superUnnamedConstructor
        ]);
        return;
      }
      if (superUnnamedConstructor.isDefaultConstructor) {
        return;
      }
    }

    if (!_typeProvider.isNonSubtypableClass(superType.element)) {
      // Don't report this diagnostic for non-subtypable classes because the
      // real problem was already reported.
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_IMPLICIT,
          declaration.name,
          [superType, _enclosingClass!.displayName]);
    }
  }

  bool _checkForNoGenerativeConstructorsInSuperclass(NamedType? superclass) {
    var superType = _enclosingClass!.supertype;
    if (superType == null) {
      return false;
    }
    if (_enclosingClass!.constructors
        .every((constructor) => constructor.isFactory)) {
      // A class with no generative constructors *can* be extended if the
      // subclass has only factory constructors.
      return false;
    }
    final superElement = superType.element;
    if (superElement.constructors.isEmpty) {
      // Exclude empty constructor set, which indicates other errors occurred.
      return false;
    }
    if (superElement.constructors
        .every((constructor) => constructor.isFactory)) {
      // For `E extends Exception`, etc., this will never work, because it has
      // no generative constructors. State this clearly to users.
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.NO_GENERATIVE_CONSTRUCTORS_IN_SUPERCLASS,
          superclass!,
          [_enclosingClass!.name, superElement.name]);
      return true;
    }
    return false;
  }

  void _checkForNonConstGenerativeEnumConstructor(ConstructorDeclaration node) {
    if (_enclosingClass is EnumElement &&
        node.constKeyword == null &&
        node.factoryKeyword == null) {
      errorReporter.reportErrorForName(
        CompileTimeErrorCode.NON_CONST_GENERATIVE_ENUM_CONSTRUCTOR,
        node,
      );
    }
  }

  /// Verify the given map [literal] either:
  /// * has `const modifier`
  /// * has explicit type arguments
  /// * is not start of the statement
  ///
  /// See [CompileTimeErrorCode.NON_CONST_MAP_AS_EXPRESSION_STATEMENT].
  void _checkForNonConstMapAsExpressionStatement3(SetOrMapLiteral literal) {
    // "const"
    if (literal.constKeyword != null) {
      return;
    }
    // has type arguments
    if (literal.typeArguments != null) {
      return;
    }
    // prepare statement
    var statement = literal.thisOrAncestorOfType<ExpressionStatement>();
    if (statement == null) {
      return;
    }
    // OK, statement does not start with map
    if (!identical(statement.beginToken, literal.beginToken)) {
      return;
    }

    // TODO(srawlins): Add any tests showing this is reported.
    errorReporter.reportErrorForNode(
        CompileTimeErrorCode.NON_CONST_MAP_AS_EXPRESSION_STATEMENT, literal);
  }

  void _checkForNonCovariantTypeParameterPositionInRepresentationType(
    ExtensionTypeDeclaration node,
    ExtensionTypeElement element,
  ) {
    final typeParameters = node.typeParameters?.typeParameters;
    if (typeParameters == null) {
      return;
    }

    final representationType = element.representation.type;

    for (final typeParameterNode in typeParameters) {
      final typeParameterElement = typeParameterNode.declaredElement!;
      final nonCovariant = representationType.accept(
        NonCovariantTypeParameterPositionVisitor(
          [typeParameterElement],
          initialVariance: Variance.covariant,
        ),
      );
      if (nonCovariant) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode
              .NON_COVARIANT_TYPE_PARAMETER_POSITION_IN_REPRESENTATION_TYPE,
          typeParameterNode,
        );
      }
    }
  }

  void _checkForNonFinalFieldInEnum(FieldDeclaration node) {
    if (node.isStatic) return;

    var variableList = node.fields;
    if (variableList.isFinal) return;

    var enclosingClass = _enclosingClass;
    if (enclosingClass == null || enclosingClass is! EnumElement) {
      return;
    }

    errorReporter.reportErrorForToken(
      CompileTimeErrorCode.NON_FINAL_FIELD_IN_ENUM,
      variableList.variables.first.name,
    );
  }

  /// Verify that the given method [declaration] of operator `[]=`, has `void`
  /// return type.
  ///
  /// See [CompileTimeErrorCode.NON_VOID_RETURN_FOR_OPERATOR].
  void _checkForNonVoidReturnTypeForOperator(MethodDeclaration declaration) {
    // check that []= operator
    if (declaration.name.lexeme != "[]=") {
      return;
    }
    // check return type
    var annotation = declaration.returnType;
    if (annotation != null) {
      DartType type = annotation.typeOrThrow;
      if (type is! VoidType) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.NON_VOID_RETURN_FOR_OPERATOR, annotation);
      }
    }
  }

  /// Verify the [namedType], used as the return type of a setter, is valid
  /// (either `null` or the type 'void').
  ///
  /// See [CompileTimeErrorCode.NON_VOID_RETURN_FOR_SETTER].
  void _checkForNonVoidReturnTypeForSetter(TypeAnnotation? namedType) {
    if (namedType != null) {
      DartType type = namedType.typeOrThrow;
      if (type is! VoidType) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.NON_VOID_RETURN_FOR_SETTER, namedType);
      }
    }
  }

  void _checkForNotInitializedNonNullableInstanceFields(
    FieldDeclaration fieldDeclaration,
  ) {
    if (!_isNonNullableByDefault) return;

    if (fieldDeclaration.isStatic) return;
    var fields = fieldDeclaration.fields;

    if (fields.isLate) return;
    if (fields.isFinal) return;

    if (_isEnclosingClassFfiStruct) return;
    if (_isEnclosingClassFfiUnion) return;

    for (var field in fields.variables) {
      var fieldElement = field.declaredElement as FieldElement;
      if (fieldElement.isAbstract || fieldElement.isExternal) continue;
      if (field.initializer != null) continue;

      var type = fieldElement.type;
      if (!typeSystem.isPotentiallyNonNullable(type)) continue;

      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.NOT_INITIALIZED_NON_NULLABLE_INSTANCE_FIELD,
        field,
        [field.name.lexeme],
      );
    }
  }

  void _checkForNotInitializedNonNullableStaticField(FieldDeclaration node) {
    if (!node.isStatic) {
      return;
    }
    _checkForNotInitializedNonNullableVariable(node.fields, false);
  }

  void _checkForNotInitializedNonNullableVariable(
    VariableDeclarationList node,
    bool topLevel,
  ) {
    if (!_isNonNullableByDefault) {
      return;
    }

    // Checked separately.
    if (node.isConst || (topLevel && node.isFinal)) {
      return;
    }

    if (node.isLate) {
      return;
    }

    var parent = node.parent;
    if (parent is FieldDeclaration) {
      if (parent.externalKeyword != null) {
        return;
      }
    } else if (parent is TopLevelVariableDeclaration) {
      if (parent.externalKeyword != null) {
        return;
      }
    }

    if (node.type == null) {
      return;
    }
    var type = node.type!.typeOrThrow;

    if (!typeSystem.isPotentiallyNonNullable(type)) {
      return;
    }

    for (var variable in node.variables) {
      if (variable.initializer == null) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.NOT_INITIALIZED_NON_NULLABLE_VARIABLE,
          variable.name,
          [variable.name.lexeme],
        );
      }
    }
  }

  /// Verify that all classes of the given [onClause] are valid.
  ///
  /// See [CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_DISALLOWED_CLASS],
  /// [CompileTimeErrorCode.MIXIN_SUPER_CLASS_CONSTRAINT_DEFERRED_CLASS].
  bool _checkForOnClauseErrorCodes(OnClause? onClause) {
    if (onClause == null) {
      return false;
    }
    bool problemReported = false;
    for (NamedType namedType in onClause.superclassConstraints) {
      DartType type = namedType.typeOrThrow;
      if (type is InterfaceType) {
        if (_checkForExtendsOrImplementsDisallowedClass(
            namedType,
            CompileTimeErrorCode
                .MIXIN_SUPER_CLASS_CONSTRAINT_DISALLOWED_CLASS)) {
          problemReported = true;
        } else {
          if (_checkForExtendsOrImplementsDeferredClass(
              namedType,
              CompileTimeErrorCode
                  .MIXIN_SUPER_CLASS_CONSTRAINT_DEFERRED_CLASS)) {
            problemReported = true;
          }
        }
      }
    }
    return problemReported;
  }

  /// Verify the given operator-method [declaration], does not have an optional
  /// parameter.
  ///
  /// This method assumes that the method declaration was tested to be an
  /// operator declaration before being called.
  ///
  /// See [CompileTimeErrorCode.OPTIONAL_PARAMETER_IN_OPERATOR].
  void _checkForOptionalParameterInOperator(MethodDeclaration declaration) {
    var parameterList = declaration.parameters;
    if (parameterList == null) {
      return;
    }

    NodeList<FormalParameter> formalParameters = parameterList.parameters;
    for (FormalParameter formalParameter in formalParameters) {
      if (formalParameter.isOptional) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.OPTIONAL_PARAMETER_IN_OPERATOR,
            formalParameter);
      }
    }
  }

  /// Via informal specification: dart-lang/language/issues/4
  ///
  /// If e is an integer literal which is not the operand of a unary minus
  /// operator, then:
  ///   - If the context type is double, it is a compile-time error if the
  ///   numerical value of e is not precisely representable by a double.
  ///   Otherwise the static type of e is double and the result of evaluating e
  ///   is a double instance representing that value.
  ///   - Otherwise (the current behavior of e, with a static type of int).
  ///
  /// and
  ///
  /// If e is -n and n is an integer literal, then
  ///   - If the context type is double, it is a compile-time error if the
  ///   numerical value of n is not precisely representable by a double.
  ///   Otherwise the static type of e is double and the result of evaluating e
  ///   is the result of calling the unary minus operator on a double instance
  ///   representing the numerical value of n.
  ///   - Otherwise (the current behavior of -n)
  void _checkForOutOfRange(IntegerLiteral node) {
    String lexeme = node.literal.lexeme;
    final bool isNegated = (node as IntegerLiteralImpl).immediatelyNegated;
    final List<Object> extraErrorArgs = [];

    final bool treatedAsDouble = node.staticType == _typeProvider.doubleType;
    final bool valid = treatedAsDouble
        ? IntegerLiteralImpl.isValidAsDouble(lexeme)
        : IntegerLiteralImpl.isValidAsInteger(lexeme, isNegated);

    if (!valid) {
      extraErrorArgs.add(isNegated ? '-$lexeme' : lexeme);

      if (treatedAsDouble) {
        // Suggest the nearest valid double (as a BigInt for printing reasons).
        extraErrorArgs.add(
            BigInt.from(IntegerLiteralImpl.nearestValidDouble(lexeme))
                .toString());
      }

      errorReporter.reportErrorForNode(
          treatedAsDouble
              ? CompileTimeErrorCode.INTEGER_LITERAL_IMPRECISE_AS_DOUBLE
              : CompileTimeErrorCode.INTEGER_LITERAL_OUT_OF_RANGE,
          node,
          extraErrorArgs);
    }
  }

  /// Check that the given named optional [parameter] does not begin with '_'.
  void _checkForPrivateOptionalParameter(FormalParameter parameter) {
    // should be named parameter
    if (!parameter.isNamed) {
      return;
    }
    // name should start with '_'
    var name = parameter.name;
    if (name == null || name.isSynthetic || !name.lexeme.startsWith('_')) {
      return;
    }

    errorReporter.reportErrorForToken(
        CompileTimeErrorCode.PRIVATE_OPTIONAL_PARAMETER, name);
  }

  /// Check whether the given constructor [declaration] is the redirecting
  /// generative constructor and references itself directly or indirectly. The
  /// [constructorElement] is the constructor element.
  ///
  /// See [CompileTimeErrorCode.RECURSIVE_CONSTRUCTOR_REDIRECT].
  void _checkForRecursiveConstructorRedirect(ConstructorDeclaration declaration,
      ConstructorElement constructorElement) {
    // we check generative constructor here
    if (declaration.factoryKeyword != null) {
      return;
    }
    // try to find redirecting constructor invocation and analyze it for
    // recursion
    for (ConstructorInitializer initializer in declaration.initializers) {
      if (initializer is RedirectingConstructorInvocation) {
        if (_hasRedirectingFactoryConstructorCycle(constructorElement)) {
          errorReporter.reportErrorForNode(
              CompileTimeErrorCode.RECURSIVE_CONSTRUCTOR_REDIRECT, initializer);
        }
        return;
      }
    }
  }

  /// Check whether the given constructor [declaration] has redirected
  /// constructor and references itself directly or indirectly. The
  /// constructor [element] is the element introduced by the declaration.
  ///
  /// See [CompileTimeErrorCode.RECURSIVE_FACTORY_REDIRECT].
  bool _checkForRecursiveFactoryRedirect(
      ConstructorDeclaration declaration, ConstructorElement element) {
    // prepare redirected constructor
    var redirectedConstructorNode = declaration.redirectedConstructor;
    if (redirectedConstructorNode == null) {
      return false;
    }
    // OK if no cycle
    if (!_hasRedirectingFactoryConstructorCycle(element)) {
      return false;
    }
    // report error
    errorReporter.reportErrorForNode(
        CompileTimeErrorCode.RECURSIVE_FACTORY_REDIRECT,
        redirectedConstructorNode);
    return true;
  }

  /// Check that the given constructor [declaration] has a valid redirected
  /// constructor.
  void _checkForRedirectingConstructorErrorCodes(
      ConstructorDeclaration declaration) {
    // Check for default values in the parameters.
    var redirectedConstructor = declaration.redirectedConstructor;
    if (redirectedConstructor == null) {
      return;
    }
    for (FormalParameter parameter in declaration.parameters.parameters) {
      if (parameter is DefaultFormalParameter &&
          parameter.defaultValue != null) {
        errorReporter.reportErrorForToken(
            CompileTimeErrorCode
                .DEFAULT_VALUE_IN_REDIRECTING_FACTORY_CONSTRUCTOR,
            parameter.name!);
      }
    }
    var redirectedElement = redirectedConstructor.staticElement;
    _checkForRedirectToNonConstConstructor(
      declaration.declaredElement!,
      redirectedElement,
      redirectedConstructor,
    );
    var redirectedClass = redirectedElement?.enclosingElement;
    if (redirectedClass is ClassElement &&
        redirectedClass.isAbstract &&
        redirectedElement != null &&
        !redirectedElement.isFactory) {
      String enclosingNamedType = _enclosingClass!.displayName;
      String constructorStrName = enclosingNamedType;
      if (declaration.name != null) {
        constructorStrName += ".${declaration.name!.lexeme}";
      }
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.REDIRECT_TO_ABSTRACT_CLASS_CONSTRUCTOR,
          redirectedConstructor,
          [constructorStrName, redirectedClass.name]);
    }
    _checkForInvalidGenerativeConstructorReference(redirectedConstructor);
  }

  /// Check whether the redirecting constructor, [element], is const, and
  /// [redirectedElement], its redirectee, is not const.
  ///
  /// See [CompileTimeErrorCode.REDIRECT_TO_NON_CONST_CONSTRUCTOR].
  void _checkForRedirectToNonConstConstructor(
    ConstructorElement element,
    ConstructorElement? redirectedElement,
    SyntacticEntity errorEntity,
  ) {
    // This constructor is const, but it redirects to a non-const constructor.
    if (redirectedElement != null &&
        element.isConst &&
        !redirectedElement.isConst) {
      errorReporter.reportErrorForOffset(
        CompileTimeErrorCode.REDIRECT_TO_NON_CONST_CONSTRUCTOR,
        errorEntity.offset,
        errorEntity.end - errorEntity.offset,
      );
    }
  }

  void _checkForReferenceBeforeDeclaration({
    required Token nameToken,
    required Element? element,
  }) {
    if (element != null &&
        _hiddenElements != null &&
        _hiddenElements!.contains(element)) {
      errorReporter.reportError(
        DiagnosticFactory().referencedBeforeDeclaration(
          errorReporter.source,
          nameToken: nameToken,
          element: element,
        ),
      );
    }
  }

  void _checkForRepeatedType(List<NamedType>? namedTypes, ErrorCode errorCode) {
    if (namedTypes == null) {
      return;
    }

    int count = namedTypes.length;
    List<bool> detectedRepeatOnIndex = List<bool>.filled(count, false);
    for (int i = 0; i < count; i++) {
      if (!detectedRepeatOnIndex[i]) {
        var type = namedTypes[i].type;
        if (type is InterfaceType) {
          var element = type.element;
          for (int j = i + 1; j < count; j++) {
            var otherNode = namedTypes[j];
            var otherType = otherNode.type;
            if (otherType is InterfaceType && otherType.element == element) {
              detectedRepeatOnIndex[j] = true;
              errorReporter
                  .reportErrorForNode(errorCode, otherNode, [element.name]);
            }
          }
        }
      }
    }
  }

  /// Check that the given rethrow [expression] is inside of a catch clause.
  ///
  /// See [CompileTimeErrorCode.RETHROW_OUTSIDE_CATCH].
  void _checkForRethrowOutsideCatch(RethrowExpression expression) {
    if (_enclosingExecutable.catchClauseLevel == 0) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.RETHROW_OUTSIDE_CATCH, expression);
    }
  }

  /// Check that if the given constructor [declaration] is generative, then
  /// it does not have an expression function body.
  ///
  /// See [CompileTimeErrorCode.RETURN_IN_GENERATIVE_CONSTRUCTOR].
  void _checkForReturnInGenerativeConstructor(
      ConstructorDeclaration declaration) {
    // ignore factory
    if (declaration.factoryKeyword != null) {
      return;
    }
    // block body (with possible return statement) is checked elsewhere
    FunctionBody body = declaration.body;
    if (body is! ExpressionFunctionBody) {
      return;
    }

    errorReporter.reportErrorForNode(
        CompileTimeErrorCode.RETURN_IN_GENERATIVE_CONSTRUCTOR, body);
  }

  /// Check that if a direct supertype of a node is sealed, then it must be in
  /// the same library.
  ///
  /// See [CompileTimeErrorCode.SEALED_CLASS_SUBTYPE_OUTSIDE_OF_LIBRARY].
  void _checkForSealedSupertypeOutsideOfLibrary(
      NamedType? superclass,
      WithClause? withClause,
      ImplementsClause? implementsClause,
      OnClause? onClause) {
    void reportErrorsForSealedClassesAndMixins(List<NamedType> namedTypes) {
      for (NamedType namedType in namedTypes) {
        final type = namedType.type;
        if (type is InterfaceType) {
          final element = type.element;
          if (element is ClassElement &&
              element.isSealed &&
              element.library != _currentLibrary) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.SEALED_CLASS_SUBTYPE_OUTSIDE_OF_LIBRARY,
                namedType,
                [element.name]);
          }
        }
      }
    }

    if (superclass != null) {
      reportErrorsForSealedClassesAndMixins([superclass]);
    }
    if (withClause != null) {
      reportErrorsForSealedClassesAndMixins(withClause.mixinTypes);
    }
    if (implementsClause != null) {
      reportErrorsForSealedClassesAndMixins(implementsClause.interfaces);
    }
    if (onClause != null) {
      reportErrorsForSealedClassesAndMixins(onClause.superclassConstraints);
    }
  }

  /// Verify that the elements in the given set [literal] are subtypes of the
  /// set's static type.
  ///
  /// See [CompileTimeErrorCode.SET_ELEMENT_TYPE_NOT_ASSIGNABLE].
  void _checkForSetElementTypeNotAssignable3(SetOrMapLiteral literal) {
    // Determine the set's element type. We base this on the static type and
    // not the literal's type arguments because in strong mode, the type
    // arguments may be inferred.
    DartType setType = literal.typeOrThrow;
    assert(setType is InterfaceTypeImpl);

    List<DartType> typeArguments = (setType as InterfaceTypeImpl).typeArguments;
    // It is possible for the number of type arguments to be inconsistent when
    // the literal is ambiguous and a non-set type was selected.
    // TODO(brianwilkerson): Unify this and _checkForMapTypeNotAssignable3 to
    //  better handle recovery situations.
    if (typeArguments.length == 1) {
      DartType setElementType = typeArguments[0];

      // Check every set element.
      var verifier = LiteralElementVerifier(
        _typeProvider,
        typeSystem,
        errorReporter,
        this,
        forSet: true,
        elementType: setElementType,
        featureSet: _featureSet!,
      );
      for (CollectionElement element in literal.elements) {
        verifier.verify(element);
      }
    }
  }

  /// Check the given [typeReference] and that the [name] is not a reference to
  /// an instance member.
  ///
  /// See [CompileTimeErrorCode.STATIC_ACCESS_TO_INSTANCE_MEMBER].
  void _checkForStaticAccessToInstanceMember(
      InterfaceElement? typeReference, SimpleIdentifier name) {
    // OK, in comment
    if (_isInComment) {
      return;
    }
    // OK, target is not a type
    if (typeReference == null) {
      return;
    }
    // prepare member Element
    var element = name.staticElement;
    if (element is ExecutableElement) {
      // OK, static
      if (element.isStatic || element is ConstructorElement) {
        return;
      }
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.STATIC_ACCESS_TO_INSTANCE_MEMBER,
          name,
          [name.name]);
    }
  }

  void _checkForThrowOfInvalidType(ThrowExpression node) {
    if (!_isNonNullableByDefault) return;

    var expression = node.expression;
    var type = node.expression.typeOrThrow;

    if (!typeSystem.isAssignableTo(type, typeSystem.objectNone,
        strictCasts: strictCasts)) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.THROW_OF_INVALID_TYPE,
        expression,
        [type],
      );
    }
  }

  /// Verify that the given [element] does not reference itself directly.
  /// If it does, report the error on the [node].
  ///
  /// See [CompileTimeErrorCode.TYPE_ALIAS_CANNOT_REFERENCE_ITSELF].
  void _checkForTypeAliasCannotReferenceItself(
    Token nameToken,
    TypeAliasElementImpl element,
  ) {
    if (element.hasSelfReference) {
      errorReporter.reportErrorForToken(
        CompileTimeErrorCode.TYPE_ALIAS_CANNOT_REFERENCE_ITSELF,
        nameToken,
      );
    }
  }

  /// Verify that the [type] is not a deferred type.
  ///
  /// See [CompileTimeErrorCode.TYPE_ANNOTATION_DEFERRED_CLASS].
  void _checkForTypeAnnotationDeferredClass(TypeAnnotation? type) {
    if (type is NamedType && type.isDeferred) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.TYPE_ANNOTATION_DEFERRED_CLASS,
        type,
        [type.qualifiedName],
      );
    }
  }

  /// Check that none of the type [parameters] references itself in its bound.
  ///
  /// See [CompileTimeErrorCode.TYPE_PARAMETER_SUPERTYPE_OF_ITS_BOUND].
  void _checkForTypeParameterBoundRecursion(List<TypeParameter> parameters) {
    Map<TypeParameterElement, TypeParameter>? elementToNode;
    for (var parameter in parameters) {
      if (parameter.bound != null) {
        if (elementToNode == null) {
          elementToNode = {};
          for (var parameter in parameters) {
            elementToNode[parameter.declaredElement!] = parameter;
          }
        }

        TypeParameter? current = parameter;
        for (var step = 0; current != null; step++) {
          final boundNode = current.bound;
          if (boundNode is NamedType) {
            var boundType = boundNode.typeOrThrow;
            boundType = boundType.extensionTypeErasure;
            current = elementToNode[boundType.element];
          } else {
            current = null;
          }
          if (step == parameters.length) {
            var element = parameter.declaredElement!;
            // This error can only occur if there is a bound, so we can safely
            // assume `element.bound` is non-`null`.
            errorReporter.reportErrorForToken(
              CompileTimeErrorCode.TYPE_PARAMETER_SUPERTYPE_OF_ITS_BOUND,
              parameter.name,
              [element.displayName, element.bound!],
            );
            break;
          }
        }
      }
    }
  }

  void _checkForTypeParameterReferencedByStatic({
    required Token name,
    required Element? element,
  }) {
    if (_enclosingExecutable.inStaticMethod || _isInStaticVariableDeclaration) {
      if (element is TypeParameterElement &&
          element.enclosingElement is InstanceElement) {
        // The class's type parameters are not in scope for static methods.
        // However all other type parameters are legal (e.g. the static method's
        // type parameters, or a local function's type parameters).
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.TYPE_PARAMETER_REFERENCED_BY_STATIC,
          name,
        );
      }
    }
  }

  /// Check that if the given generative [constructor] has neither an explicit
  /// super constructor invocation nor a redirecting constructor invocation,
  /// that the superclass has a default generative constructor.
  ///
  /// See [CompileTimeErrorCode.UNDEFINED_CONSTRUCTOR_IN_INITIALIZER_DEFAULT],
  /// [CompileTimeErrorCode.NON_GENERATIVE_CONSTRUCTOR], and
  /// [CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_EXPLICIT].
  void _checkForUndefinedConstructorInInitializerImplicit(
      ConstructorDeclaration constructor) {
    if (_enclosingClass == null) {
      return;
    }

    // Ignore if the constructor is not generative.
    if (constructor.factoryKeyword != null) {
      return;
    }

    // Ignore if the constructor is external. See
    // https://github.com/dart-lang/language/issues/869.
    if (constructor.externalKeyword != null) {
      return;
    }

    // Ignore if the constructor has either an implicit super constructor
    // invocation or a redirecting constructor invocation.
    for (ConstructorInitializer constructorInitializer
        in constructor.initializers) {
      if (constructorInitializer is SuperConstructorInvocation ||
          constructorInitializer is RedirectingConstructorInvocation) {
        return;
      }
    }

    // Check to see whether the superclass has a non-factory unnamed
    // constructor.
    var superType = _enclosingClass!.supertype;
    if (superType == null) {
      return;
    }
    final superElement = superType.element;

    if (superElement.constructors
        .every((constructor) => constructor.isFactory)) {
      // Already reported [NO_GENERATIVE_CONSTRUCTORS_IN_SUPERCLASS].
      return;
    }

    var superUnnamedConstructor = superElement.unnamedConstructor;
    superUnnamedConstructor = superUnnamedConstructor != null
        ? _currentLibrary.toLegacyElementIfOptOut(superUnnamedConstructor)
        : superUnnamedConstructor;
    if (superUnnamedConstructor == null) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.UNDEFINED_CONSTRUCTOR_IN_INITIALIZER_DEFAULT,
        constructor.returnType,
        [superElement.name],
      );
      return;
    }

    if (superUnnamedConstructor.isFactory) {
      errorReporter.reportErrorForNode(
        CompileTimeErrorCode.NON_GENERATIVE_CONSTRUCTOR,
        constructor.returnType,
        [superUnnamedConstructor],
      );
      return;
    }

    var requiredPositionalParameterCount = superUnnamedConstructor.parameters
        .where((parameter) => parameter.isRequiredPositional)
        .length;
    var requiredNamedParameters = superUnnamedConstructor.parameters
        .where((parameter) => parameter.isRequiredNamed)
        .map((parameter) => parameter.name)
        .toSet();

    void reportError(ErrorCode errorCode, List<Object> arguments) {
      Identifier returnType = constructor.returnType;
      var name = constructor.name;
      int offset = returnType.offset;
      int length = (name != null ? name.end : returnType.end) - offset;
      errorReporter.reportErrorForOffset(errorCode, offset, length, arguments);
    }

    if (!_currentLibrary.featureSet.isEnabled(Feature.super_parameters)) {
      if (requiredPositionalParameterCount != 0 ||
          requiredNamedParameters.isNotEmpty) {
        reportError(
          CompileTimeErrorCode.NO_DEFAULT_SUPER_CONSTRUCTOR_EXPLICIT,
          [superType],
        );
      }
      return;
    }

    var superParametersResult = verifySuperFormalParameters(
      constructor: constructor,
      errorReporter: errorReporter,
    );
    requiredNamedParameters.removeAll(
      superParametersResult.namedArgumentNames,
    );

    if (requiredPositionalParameterCount >
            superParametersResult.positionalArgumentCount ||
        requiredNamedParameters.isNotEmpty) {
      reportError(
        CompileTimeErrorCode.IMPLICIT_SUPER_INITIALIZER_MISSING_ARGUMENTS,
        [superType],
      );
    }
  }

  void _checkForUnnecessaryNullAware(Expression target, Token operator) {
    if (!_isNonNullableByDefault) {
      return;
    }

    if (target is SuperExpression) {
      return;
    }

    ErrorCode errorCode;
    Token endToken = operator;
    List<Object> arguments = const [];
    if (operator.type == TokenType.QUESTION) {
      errorCode = StaticWarningCode.INVALID_NULL_AWARE_OPERATOR;
      endToken = operator.next!;
      arguments = ['?[', '['];
    } else if (operator.type == TokenType.QUESTION_PERIOD) {
      errorCode = StaticWarningCode.INVALID_NULL_AWARE_OPERATOR;
      arguments = [operator.lexeme, '.'];
    } else if (operator.type == TokenType.QUESTION_PERIOD_PERIOD) {
      errorCode = StaticWarningCode.INVALID_NULL_AWARE_OPERATOR;
      arguments = [operator.lexeme, '..'];
    } else if (operator.type == TokenType.PERIOD_PERIOD_PERIOD_QUESTION) {
      errorCode = StaticWarningCode.INVALID_NULL_AWARE_OPERATOR;
      arguments = [operator.lexeme, '...'];
    } else if (operator.type == TokenType.BANG) {
      errorCode = StaticWarningCode.UNNECESSARY_NON_NULL_ASSERTION;
    } else {
      return;
    }

    /// If the operator is not valid because the target already makes use of a
    /// null aware operator, return the null aware operator from the target.
    Token? previousShortCircuitingOperator(Expression? target) {
      if (target is PropertyAccess) {
        var operator = target.operator;
        var type = operator.type;
        if (type == TokenType.QUESTION_PERIOD) {
          var realTarget = target.realTarget;
          return previousShortCircuitingOperator(realTarget) ?? operator;
        }
      } else if (target is IndexExpression) {
        if (target.question != null) {
          var realTarget = target.realTarget;
          return previousShortCircuitingOperator(realTarget) ?? target.question;
        }
      } else if (target is MethodInvocation) {
        var operator = target.operator;
        var type = operator?.type;
        if (type == TokenType.QUESTION_PERIOD) {
          var realTarget = target.realTarget;
          return previousShortCircuitingOperator(realTarget) ?? operator;
        }
      }
      return null;
    }

    var targetType = target.staticType;
    if (target is ExtensionOverride) {
      var arguments = target.argumentList.arguments;
      if (arguments.length == 1) {
        targetType = arguments[0].typeOrThrow;
      } else {
        return;
      }
    } else if (targetType == null) {
      if (target is Identifier) {
        final targetElement = target.staticElement;
        if (targetElement is InterfaceElement ||
            targetElement is ExtensionElement ||
            targetElement is TypeAliasElement) {
          errorReporter.reportErrorForOffset(
            errorCode,
            operator.offset,
            endToken.end - operator.offset,
            arguments,
          );
        }
      }
      return;
    }

    if (typeSystem.isStrictlyNonNullable(targetType)) {
      if (errorCode == StaticWarningCode.INVALID_NULL_AWARE_OPERATOR) {
        var previousOperator = previousShortCircuitingOperator(target);
        if (previousOperator != null) {
          errorReporter.reportError(DiagnosticFactory()
              .invalidNullAwareAfterShortCircuit(
                  errorReporter.source,
                  operator.offset,
                  endToken.end - operator.offset,
                  arguments,
                  previousOperator));
          return;
        }
      }
      errorReporter.reportErrorForOffset(
        errorCode,
        operator.offset,
        endToken.end - operator.offset,
        arguments,
      );
    }
  }

  /// Check that if the given [name] is a reference to a static member it is
  /// defined in the enclosing class rather than in a superclass.
  ///
  /// See
  /// [CompileTimeErrorCode.UNQUALIFIED_REFERENCE_TO_NON_LOCAL_STATIC_MEMBER].
  void _checkForUnqualifiedReferenceToNonLocalStaticMember(
      SimpleIdentifier name) {
    var element = name.writeOrReadElement;
    if (element == null || element is TypeParameterElement) {
      return;
    }
    var enclosingElement = element.enclosingElement;
    if (identical(enclosingElement, _enclosingClass)) {
      return;
    }
    if (enclosingElement is! InterfaceElement) {
      return;
    }
    if (element is ExecutableElement && !element.isStatic) {
      return;
    }
    if (element is MethodElement) {
      // Invalid methods are reported in
      // [MethodInvocationResolver._resolveReceiverNull].
      return;
    }
    if (_enclosingExtension != null) {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode
              .UNQUALIFIED_REFERENCE_TO_STATIC_MEMBER_OF_EXTENDED_TYPE,
          name,
          [enclosingElement.displayName]);
    } else {
      errorReporter.reportErrorForNode(
          CompileTimeErrorCode.UNQUALIFIED_REFERENCE_TO_NON_LOCAL_STATIC_MEMBER,
          name,
          [enclosingElement.displayName]);
    }
  }

  void _checkForValidField(FieldFormalParameter parameter) {
    var parent2 = parameter.parent?.parent;
    if (parent2 is! ConstructorDeclaration &&
        parent2?.parent is! ConstructorDeclaration) {
      return;
    }
    ParameterElement element = parameter.declaredElement!;
    if (element is FieldFormalParameterElement) {
      var fieldElement = element.field;
      if (fieldElement == null || fieldElement.isSynthetic) {
        errorReporter.reportErrorForNode(
            CompileTimeErrorCode.INITIALIZING_FORMAL_FOR_NON_EXISTENT_FIELD,
            parameter,
            [parameter.name.lexeme]);
      } else {
        var parameterElement = parameter.declaredElement!;
        if (parameterElement is FieldFormalParameterElementImpl) {
          DartType declaredType = parameterElement.type;
          DartType fieldType = fieldElement.type;
          if (fieldElement.isSynthetic) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.INITIALIZING_FORMAL_FOR_NON_EXISTENT_FIELD,
                parameter,
                [parameter.name.lexeme]);
          } else if (fieldElement.isStatic) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.INITIALIZER_FOR_STATIC_FIELD,
                parameter,
                [parameter.name.lexeme]);
          } else if (!typeSystem.isSubtypeOf(declaredType, fieldType)) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.FIELD_INITIALIZING_FORMAL_NOT_ASSIGNABLE,
                parameter,
                [declaredType, fieldType]);
          }
        } else {
          if (fieldElement.isSynthetic) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.INITIALIZING_FORMAL_FOR_NON_EXISTENT_FIELD,
                parameter,
                [parameter.name.lexeme]);
          } else if (fieldElement.isStatic) {
            errorReporter.reportErrorForNode(
                CompileTimeErrorCode.INITIALIZER_FOR_STATIC_FIELD,
                parameter,
                [parameter.name.lexeme]);
          }
        }
      }
    }
//        else {
// TODO(jwren): Report error, constructor initializer variable is a top level element
// (Either here or in ErrorVerifier.checkForAllFinalInitializedErrorCodes)
//        }
  }

  /// Verify the given operator-method [declaration], has correct number of
  /// parameters.
  ///
  /// This method assumes that the method declaration was tested to be an
  /// operator declaration before being called.
  ///
  /// See [CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_OPERATOR].
  bool _checkForWrongNumberOfParametersForOperator(
      MethodDeclaration declaration) {
    // prepare number of parameters
    var parameterList = declaration.parameters;
    if (parameterList == null) {
      return false;
    }
    int numParameters = parameterList.parameters.length;
    // prepare operator name
    final nameToken = declaration.name;
    final name = nameToken.lexeme;
    // check for exact number of parameters
    int expected = -1;
    if ("[]=" == name) {
      expected = 2;
    } else if ("<" == name ||
        ">" == name ||
        "<=" == name ||
        ">=" == name ||
        "==" == name ||
        "+" == name ||
        "/" == name ||
        "~/" == name ||
        "*" == name ||
        "%" == name ||
        "|" == name ||
        "^" == name ||
        "&" == name ||
        "<<" == name ||
        ">>" == name ||
        ">>>" == name ||
        "[]" == name) {
      expected = 1;
    } else if ("~" == name) {
      expected = 0;
    }
    if (expected != -1 && numParameters != expected) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_OPERATOR,
          nameToken,
          [name, expected, numParameters]);
      return true;
    } else if ("-" == name && numParameters > 1) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_OPERATOR_MINUS,
          nameToken,
          [numParameters]);
      return true;
    }
    return false;
  }

  /// Verify that the given setter [parameterList] has only one required
  /// parameter. The [setterName] is the name of the setter to report problems
  /// on.
  ///
  /// This method assumes that the method declaration was tested to be a setter
  /// before being called.
  ///
  /// See [CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER].
  void _checkForWrongNumberOfParametersForSetter(
      Token setterName, FormalParameterList? parameterList) {
    if (parameterList == null) {
      return;
    }

    NodeList<FormalParameter> parameters = parameterList.parameters;
    if (parameters.length != 1 || !parameters[0].isRequiredPositional) {
      errorReporter.reportErrorForToken(
          CompileTimeErrorCode.WRONG_NUMBER_OF_PARAMETERS_FOR_SETTER,
          setterName);
    }
  }

  void _checkForWrongTypeParameterVarianceInField(FieldDeclaration node) {
    if (_enclosingClass != null) {
      for (var typeParameter in _enclosingClass!.typeParameters) {
        // TODO(kallentu): : Clean up TypeParameterElementImpl casting once
        // variance is added to the interface.
        if (!(typeParameter as TypeParameterElementImpl).isLegacyCovariant) {
          var fields = node.fields;
          var fieldElement = fields.variables.first.declaredElement!;
          var fieldName = fields.variables.first.name;
          Variance fieldVariance = Variance(typeParameter, fieldElement.type);

          _checkForWrongVariancePosition(
              fieldVariance, typeParameter, fieldName);
          if (!fields.isFinal && node.covariantKeyword == null) {
            _checkForWrongVariancePosition(
                Variance.contravariant.combine(fieldVariance),
                typeParameter,
                fieldName);
          }
        }
      }
    }
  }

  void _checkForWrongTypeParameterVarianceInMethod(MethodDeclaration method) {
    // Only need to report errors for parameters with explicitly defined type
    // parameters in classes or mixins.
    if (_enclosingClass == null) {
      return;
    }

    for (var typeParameter in _enclosingClass!.typeParameters) {
      // TODO(kallentu): : Clean up TypeParameterElementImpl casting once
      // variance is added to the interface.
      if ((typeParameter as TypeParameterElementImpl).isLegacyCovariant) {
        continue;
      }

      var methodTypeParameters = method.typeParameters?.typeParameters;
      if (methodTypeParameters != null) {
        for (var methodTypeParameter in methodTypeParameters) {
          if (methodTypeParameter.bound == null) {
            continue;
          }
          var methodTypeParameterVariance = Variance.invariant.combine(
            Variance(typeParameter, methodTypeParameter.bound!.typeOrThrow),
          );
          _checkForWrongVariancePosition(
              methodTypeParameterVariance, typeParameter, methodTypeParameter);
        }
      }

      var methodParameters = method.parameters?.parameters;
      if (methodParameters != null) {
        for (var methodParameter in methodParameters) {
          var methodParameterElement = methodParameter.declaredElement!;
          if (methodParameterElement.isCovariant) {
            continue;
          }
          var methodParameterVariance = Variance.contravariant.combine(
            Variance(typeParameter, methodParameterElement.type),
          );
          _checkForWrongVariancePosition(
              methodParameterVariance, typeParameter, methodParameter);
        }
      }

      var returnType = method.returnType;
      if (returnType != null) {
        var methodReturnTypeVariance =
            Variance(typeParameter, returnType.typeOrThrow);
        _checkForWrongVariancePosition(
            methodReturnTypeVariance, typeParameter, returnType);
      }
    }
  }

  void _checkForWrongTypeParameterVarianceInSuperinterfaces() {
    void checkOne(DartType? superInterface) {
      if (superInterface != null) {
        for (var typeParameter in _enclosingClass!.typeParameters) {
          var superVariance = Variance(typeParameter, superInterface);
          // TODO(kallentu): : Clean up TypeParameterElementImpl casting once
          // variance is added to the interface.
          var typeParameterElementImpl =
              typeParameter as TypeParameterElementImpl;
          // Let `D` be a class or mixin declaration, let `S` be a direct
          // superinterface of `D`, and let `X` be a type parameter declared by
          // `D`.
          // If `X` is an `out` type parameter, it can only occur in `S` in an
          // covariant or unrelated position.
          // If `X` is an `in` type parameter, it can only occur in `S` in an
          // contravariant or unrelated position.
          // If `X` is an `inout` type parameter, it can occur in `S` in any
          // position.
          if (!superVariance
              .greaterThanOrEqual(typeParameterElementImpl.variance)) {
            if (!typeParameterElementImpl.isLegacyCovariant) {
              errorReporter.reportErrorForElement(
                CompileTimeErrorCode
                    .WRONG_EXPLICIT_TYPE_PARAMETER_VARIANCE_IN_SUPERINTERFACE,
                typeParameter,
                [
                  typeParameter.name,
                  typeParameterElementImpl.variance.toKeywordString(),
                  superVariance.toKeywordString(),
                  superInterface
                ],
              );
            } else {
              errorReporter.reportErrorForElement(
                CompileTimeErrorCode
                    .WRONG_TYPE_PARAMETER_VARIANCE_IN_SUPERINTERFACE,
                typeParameter,
                [typeParameter.name, superInterface],
              );
            }
          }
        }
      }
    }

    checkOne(_enclosingClass!.supertype);
    _enclosingClass!.interfaces.forEach(checkOne);
    _enclosingClass!.mixins.forEach(checkOne);

    final enclosingClass = _enclosingClass;
    if (enclosingClass is MixinElement) {
      enclosingClass.superclassConstraints.forEach(checkOne);
    }
  }

  /// Check for invalid variance positions in members of a class or mixin.
  ///
  /// Let `C` be a class or mixin declaration with type parameter `T`.
  /// If `T` is an `out` type parameter then `T` can only appear in covariant
  /// positions within the accessors and methods of `C`.
  /// If `T` is an `in` type parameter then `T` can only appear in contravariant
  /// positions within the accessors and methods of `C`.
  /// If `T` is an `inout` type parameter or a type parameter with no explicit
  /// variance modifier then `T` can appear in any variant position within the
  /// accessors and methods of `C`.
  ///
  /// Errors should only be reported in classes and mixins since those are the
  /// only components that allow explicit variance modifiers.
  void _checkForWrongVariancePosition(Variance variance,
      TypeParameterElement typeParameter, SyntacticEntity errorTarget) {
    TypeParameterElementImpl typeParameterImpl =
        typeParameter as TypeParameterElementImpl;
    if (!variance.greaterThanOrEqual(typeParameterImpl.variance)) {
      errorReporter.reportErrorForOffset(
        CompileTimeErrorCode.WRONG_TYPE_PARAMETER_VARIANCE_POSITION,
        errorTarget.offset,
        errorTarget.length,
        [
          typeParameterImpl.variance.toKeywordString(),
          typeParameterImpl.name,
          variance.toKeywordString()
        ],
      );
    }
  }

  /// Verify that the current class does not have the same class in the
  /// 'extends' and 'implements' clauses.
  ///
  /// See [CompileTimeErrorCode.IMPLEMENTS_SUPER_CLASS].
  void _checkImplementsSuperClass(ImplementsClause? implementsClause) {
    if (implementsClause == null) {
      return;
    }

    var superElement = _enclosingClass!.supertype?.element;
    if (superElement == null) {
      return;
    }

    for (var interfaceNode in implementsClause.interfaces) {
      var type = interfaceNode.type;
      if (type is InterfaceType && type.element == superElement) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.IMPLEMENTS_SUPER_CLASS,
          interfaceNode,
          [superElement],
        );
      }
    }
  }

  /// Checks the class for problems with the superclass, mixins, or implemented
  /// interfaces.
  void _checkMixinInheritance(MixinDeclaration node, OnClause? onClause,
      ImplementsClause? implementsClause) {
    // Only check for all of the inheritance logic around clauses if there
    // isn't an error code such as "Cannot implement double" already.
    if (!_checkForOnClauseErrorCodes(onClause) &&
        !_checkForImplementsClauseErrorCodes(implementsClause)) {
//      _checkForImplicitDynamicType(superclass);
      _checkForRepeatedType(
        onClause?.superclassConstraints,
        CompileTimeErrorCode.ON_REPEATED,
      );
      _checkForRepeatedType(
        implementsClause?.interfaces,
        CompileTimeErrorCode.IMPLEMENTS_REPEATED,
      );
      _checkForConflictingGenerics(node);
      _checkForBaseClassOrMixinImplementedOutsideOfLibrary(implementsClause);
      _checkForFinalSupertypeOutsideOfLibrary(
          null, null, implementsClause, onClause);
      _checkForSealedSupertypeOutsideOfLibrary(
          null, null, implementsClause, onClause);
    }
  }

  /// Verify that the current class does not have the same class in the
  /// 'extends' and 'with' clauses.
  ///
  /// See [CompileTimeErrorCode.IMPLEMENTS_SUPER_CLASS].
  void _checkMixinsSuperClass(WithClause? withClause) {
    if (withClause == null) {
      return;
    }

    var superElement = _enclosingClass!.supertype?.element;
    if (superElement == null) {
      return;
    }

    for (var mixinNode in withClause.mixinTypes) {
      var type = mixinNode.type;
      if (type is InterfaceType && type.element == superElement) {
        errorReporter.reportErrorForNode(
          CompileTimeErrorCode.MIXINS_SUPER_CLASS,
          mixinNode,
          [superElement],
        );
      }
    }
  }

  void _checkUseOfCovariantInParameters(FormalParameterList node) {
    var parent = node.parent;
    if (_enclosingClass != null && parent is MethodDeclaration) {
      // Either [parent] is a static method, in which case `EXTRANEOUS_MODIFIER`
      // is reported by the parser, or [parent] is an instance method, in which
      // case any use of `covariant` is legal.
      return;
    }

    if (_enclosingExtension != null) {
      // `INVALID_USE_OF_COVARIANT_IN_EXTENSION` is reported by the parser.
      return;
    }

    if (parent is FunctionExpression) {
      var parent2 = parent.parent;
      if (parent2 is FunctionDeclaration && parent2.parent is CompilationUnit) {
        // `EXTRANEOUS_MODIFIER` is reported by the parser, for library-level
        // functions.
        return;
      }
    }

    NodeList<FormalParameter> parameters = node.parameters;
    int length = parameters.length;
    for (int i = 0; i < length; i++) {
      FormalParameter parameter = parameters[i];
      if (parameter is DefaultFormalParameter) {
        parameter = parameter.parameter;
      }
      var keyword = parameter.covariantKeyword;
      if (keyword != null) {
        errorReporter.reportErrorForToken(
          CompileTimeErrorCode.INVALID_USE_OF_COVARIANT,
          keyword,
        );
      }
    }
  }

  void _checkUseOfDefaultValuesInParameters(FormalParameterList node) {
    if (!_isNonNullableByDefault) return;

    var defaultValuesAreExpected = () {
      var parent = node.parent;
      if (parent is ConstructorDeclaration) {
        if (parent.externalKeyword != null) {
          return false;
        } else if (parent.factoryKeyword != null &&
            parent.redirectedConstructor != null) {
          return false;
        }
        return true;
      } else if (parent is FunctionExpression) {
        var parent2 = parent.parent;
        if (parent2 is FunctionDeclaration && parent2.externalKeyword != null) {
          return false;
        } else if (parent.body is NativeFunctionBody) {
          return false;
        }
        return true;
      } else if (parent is MethodDeclaration) {
        if (parent.isAbstract) {
          return false;
        } else if (parent.externalKeyword != null) {
          return false;
        } else if (parent.body is NativeFunctionBody) {
          return false;
        }
        return true;
      }
      return false;
    }();

    for (var parameter in node.parameters) {
      if (parameter is DefaultFormalParameter) {
        if (parameter.isRequiredNamed) {
          if (parameter.defaultValue != null) {
            final errorTarget = _parameterName(parameter) ?? parameter;
            errorReporter.reportErrorForOffset(
              CompileTimeErrorCode.DEFAULT_VALUE_ON_REQUIRED_PARAMETER,
              errorTarget.offset,
              errorTarget.length,
            );
          }
        } else if (defaultValuesAreExpected) {
          var parameterElement = parameter.declaredElement!;
          if (!parameterElement.hasDefaultValue) {
            var type = parameterElement.type;
            if (typeSystem.isPotentiallyNonNullable(type)) {
              final parameterName = _parameterName(parameter);
              final errorTarget = parameterName ?? parameter;

              List<Object> arguments = const [];
              ErrorCode errorCode;
              if (parameterElement.hasRequired) {
                errorCode = CompileTimeErrorCode
                    .MISSING_DEFAULT_VALUE_FOR_PARAMETER_WITH_ANNOTATION;
              } else {
                errorCode = parameterElement.isPositional
                    ? CompileTimeErrorCode
                        .MISSING_DEFAULT_VALUE_FOR_PARAMETER_POSITIONAL
                    : CompileTimeErrorCode.MISSING_DEFAULT_VALUE_FOR_PARAMETER;
                arguments = [parameterName?.lexeme ?? '?'];
              }
              errorReporter.reportErrorForOffset(
                  errorCode, errorTarget.offset, errorTarget.length, arguments);
            }
          }
        }
      }
    }
  }

  /// Given an [expression] in a switch case whose value is expected to be an
  /// enum constant, return the name of the constant.
  String? _getConstantName(Expression expression) {
    // TODO(brianwilkerson): Convert this to return the element representing the
    // constant.
    if (expression is SimpleIdentifier) {
      return expression.name;
    } else if (expression is PrefixedIdentifier) {
      return expression.identifier.name;
    } else if (expression is PropertyAccess) {
      return expression.propertyName.name;
    }
    return null;
  }

  /// Return the name of the library that defines given [element].
  String _getLibraryName(Element? element) {
    if (element == null) {
      return '';
    }
    var library = element.library;
    if (library == null) {
      return '';
    }
    final imports = _currentLibrary.libraryImports;
    int count = imports.length;
    for (int i = 0; i < count; i++) {
      if (identical(imports[i].importedLibrary, library)) {
        return library.definingCompilationUnit.source.uri.toString();
      }
    }
    List<String> indirectSources = <String>[];
    for (int i = 0; i < count; i++) {
      var importedLibrary = imports[i].importedLibrary;
      if (importedLibrary != null) {
        for (LibraryElement exportedLibrary
            in importedLibrary.exportedLibraries) {
          if (identical(exportedLibrary, library)) {
            indirectSources.add(
                importedLibrary.definingCompilationUnit.source.uri.toString());
          }
        }
      }
    }
    int indirectCount = indirectSources.length;
    StringBuffer buffer = StringBuffer();
    buffer.write(library.definingCompilationUnit.source.uri.toString());
    if (indirectCount > 0) {
      buffer.write(" (via ");
      if (indirectCount > 1) {
        indirectSources.sort();
        buffer.write(indirectSources.quotedAndCommaSeparatedWithAnd);
      } else {
        buffer.write(indirectSources[0]);
      }
      buffer.write(")");
    }
    return buffer.toString();
  }

  /// Return `true` if the given [constructor] redirects to itself, directly or
  /// indirectly.
  bool _hasRedirectingFactoryConstructorCycle(ConstructorElement constructor) {
    Set<ConstructorElement> constructors = HashSet<ConstructorElement>();
    ConstructorElement? current = constructor;
    while (current != null) {
      if (constructors.contains(current)) {
        return identical(current, constructor);
      }
      constructors.add(current);
      current = current.redirectedConstructor?.declaration;
    }
    return false;
  }

  /// Returns `true` if the given [library] is the `dart:ffi` library.
  bool _isDartFfiLibrary(LibraryElement library) => library.name == 'dart.ffi';

  /// Return `true` if the given [identifier] is in a location where it is
  /// allowed to resolve to a static member of a supertype.
  bool _isUnqualifiedReferenceToNonLocalStaticMemberAllowed(
      SimpleIdentifier identifier) {
    if (identifier.inDeclarationContext()) {
      return true;
    }
    var parent = identifier.parent;
    if (parent is Annotation) {
      return identical(parent.constructorName, identifier);
    }
    if (parent is CommentReference) {
      return true;
    }
    if (parent is ConstructorName) {
      return identical(parent.name, identifier);
    }
    if (parent is MethodInvocation) {
      return identical(parent.methodName, identifier);
    }
    if (parent is PrefixedIdentifier) {
      return identical(parent.identifier, identifier);
    }
    if (parent is PropertyAccess) {
      return identical(parent.propertyName, identifier);
    }
    if (parent is SuperConstructorInvocation) {
      return identical(parent.constructorName, identifier);
    }
    return false;
  }

  /// Return `true` if the [importElement] is the internal library `dart:_wasm`
  /// and the current library is either `package:js/js.dart` or is in
  /// `package:ui`.
  bool _isWasm(LibraryImportElement importElement) {
    var importedUri = importElement.importedLibrary?.source.uri.toString();
    if (importedUri != 'dart:_wasm') {
      return false;
    }
    var importingUri = _currentLibrary.source.uri.toString();
    if (importingUri == 'package:js/js.dart') {
      return true;
    } else if (importingUri.startsWith('package:ui/')) {
      return true;
    }
    return false;
  }

  /// Checks whether a `final`, `base` or `interface` modifier can be ignored.
  ///
  /// Checks whether a subclass in the current library
  /// can ignore a class modifier of a declaration in [superLibrary].
  ///
  /// Only true if the supertype library is a platform library, and
  /// either the current library is also a platform library,
  /// or the current library has a language version which predates
  /// class modifiers
  bool _mayIgnoreClassModifiers(LibraryElement superLibrary) {
    // Only modifiers in platform libraries can be ignored.
    if (!superLibrary.isInSdk) return false;

    // Modifiers in 'dart:ffi' can't be ignored in pre-feature code.
    if (_isDartFfiLibrary(superLibrary)) {
      return false;
    }

    // Other platform libraries can ignore modifiers.
    if (_currentLibrary.isInSdk) return true;

    // Libraries predating class modifiers can ignore platform modifiers.
    return !_currentLibrary.featureSet.isEnabled(Feature.class_modifiers);
  }

  /// Return the name of the [parameter], or `null` if the parameter does not
  /// have a name.
  Token? _parameterName(FormalParameter parameter) {
    if (parameter is NormalFormalParameter) {
      return parameter.name;
    } else if (parameter is DefaultFormalParameter) {
      return parameter.parameter.name;
    }
    return null;
  }

  void _reportMacroDiagnostics(
    MacroTargetElement element,
    List<Annotation> metadata,
  ) {
    DiagnosticMessage convertMessage(MacroDiagnosticMessage object) {
      final target = object.target;
      switch (target) {
        case ApplicationMacroDiagnosticTarget():
          final node = metadata[target.annotationIndex];
          return DiagnosticMessageImpl(
            filePath: element.source!.fullName,
            length: node.length,
            message: object.message,
            offset: node.offset,
            url: null,
          );
        case ElementMacroDiagnosticTarget():
          final element = target.element;
          return DiagnosticMessageImpl(
            filePath: element.source!.fullName,
            length: element.nameLength,
            message: object.message,
            offset: element.nameOffset,
            url: null,
          );
      }
    }

    for (final diagnostic in element.macroDiagnostics) {
      switch (diagnostic) {
        case ArgumentMacroDiagnostic():
          // TODO(scheglov): implement
          throw UnimplementedError();
        case DeclarationsIntrospectionCycleDiagnostic():
          var messages = diagnostic.components.map<DiagnosticMessage>(
            (component) {
              var target = _macroAnnotationNameIdentifier(
                element: component.element,
                annotationIndex: component.annotationIndex,
              );
              var introspectedName = component.introspectedElement.name;
              return DiagnosticMessageImpl(
                filePath: component.element.source!.fullName,
                length: target.length,
                message:
                    "The macro application introspects '$introspectedName'.",
                offset: target.offset,
                url: null,
              );
            },
          ).toList();
          errorReporter.reportErrorForNode(
            CompileTimeErrorCode.MACRO_DECLARATIONS_PHASE_INTROSPECTION_CYCLE,
            _macroAnnotationNameIdentifier(
              element: element,
              annotationIndex: diagnostic.annotationIndex,
            ),
            [diagnostic.introspectedElement.name!],
            messages,
          );
        case ExceptionMacroDiagnostic():
          // TODO(scheglov): implement
          throw UnimplementedError();
        case MacroDiagnostic():
          final errorCode = switch (diagnostic.severity) {
            macro.Severity.info => HintCode.MACRO_INFO,
            macro.Severity.warning => WarningCode.MACRO_WARNING,
            macro.Severity.error => CompileTimeErrorCode.MACRO_ERROR,
          };
          final target = diagnostic.message.target;
          switch (target) {
            case ApplicationMacroDiagnosticTarget():
              errorReporter.reportErrorForNode(
                errorCode,
                metadata[target.annotationIndex],
                [diagnostic.message.message],
                diagnostic.contextMessages.map(convertMessage).toList(),
              );
            case ElementMacroDiagnosticTarget():
              errorReporter.reportErrorForElement(
                errorCode,
                target.element,
                [diagnostic.message.message],
                diagnostic.contextMessages.map(convertMessage).toList(),
              );
          }
      }
    }
  }

  void _withEnclosingExecutable(
    ExecutableElement element,
    void Function() operation,
  ) {
    var current = _enclosingExecutable;
    try {
      _enclosingExecutable = EnclosingExecutableContext(element);
      _returnTypeVerifier.enclosingExecutable = _enclosingExecutable;
      operation();
    } finally {
      _enclosingExecutable = current;
      _returnTypeVerifier.enclosingExecutable = _enclosingExecutable;
    }
  }

  void _withHiddenElements(List<Statement> statements, void Function() f) {
    _hiddenElements = HiddenElements(_hiddenElements, statements);
    try {
      f();
    } finally {
      _hiddenElements = _hiddenElements!.outerElements;
    }
  }

  void _withHiddenElementsGuardedPattern(
      GuardedPatternImpl guardedPattern, void Function() f) {
    _hiddenElements =
        HiddenElements.forGuardedPattern(_hiddenElements, guardedPattern);
    try {
      f();
    } finally {
      _hiddenElements = _hiddenElements!.outerElements;
    }
  }

  /// Return [FieldElement]s that are declared in the [ClassDeclaration] with
  /// the given [constructor], but are not initialized.
  static List<FieldElement> computeNotInitializedFields(
      ConstructorDeclaration constructor) {
    Set<FieldElement> fields = <FieldElement>{};
    var classDeclaration = constructor.parent as ClassDeclaration;
    for (ClassMember fieldDeclaration in classDeclaration.members) {
      if (fieldDeclaration is FieldDeclaration) {
        for (VariableDeclaration field in fieldDeclaration.fields.variables) {
          if (field.initializer == null) {
            fields.add(field.declaredElement as FieldElement);
          }
        }
      }
    }

    List<FormalParameter> parameters = constructor.parameters.parameters;
    for (FormalParameter parameter in parameters) {
      if (parameter is DefaultFormalParameter) {
        parameter = parameter.parameter;
      }
      if (parameter is FieldFormalParameter) {
        final element =
            parameter.declaredElement as FieldFormalParameterElement;
        fields.remove(element.field);
      }
    }

    for (ConstructorInitializer initializer in constructor.initializers) {
      if (initializer is ConstructorFieldInitializer) {
        fields.remove(initializer.fieldName.staticElement);
      }
    }

    return fields.toList();
  }

  static SimpleIdentifier _macroAnnotationNameIdentifier({
    required ElementImpl element,
    required int annotationIndex,
  }) {
    var annotation = element.metadata[annotationIndex];
    annotation as ElementAnnotationImpl;
    var annotationNode = annotation.annotationAst;
    var fullName = annotationNode.name;
    if (fullName is PrefixedIdentifierImpl) {
      return fullName.identifier;
    } else {
      return fullName as SimpleIdentifierImpl;
    }
  }
}

/// A record of the elements that will be declared in some scope (block), but
/// are not yet declared.
class HiddenElements {
  /// The elements hidden in outer scopes, or `null` if this is the outermost
  /// scope.
  final HiddenElements? outerElements;

  /// A set containing the elements that will be declared in this scope, but are
  /// not yet declared.
  final Set<Element> _elements = HashSet<Element>();

  /// Initialize a newly created set of hidden elements to include all of the
  /// elements defined in the set of [outerElements] and all of the elements
  /// declared in the given [statements].
  HiddenElements(this.outerElements, List<Statement> statements) {
    _initializeElements(statements);
  }

  /// Initialize a newly created set of hidden elements to include all of the
  /// elements defined in the set of [outerElements] and all of the elements
  /// declared in the given [guardedPattern].
  HiddenElements.forGuardedPattern(
    this.outerElements,
    GuardedPatternImpl guardedPattern,
  ) {
    _elements.addAll(guardedPattern.variables.values);
  }

  /// Return `true` if this set of elements contains the given [element].
  bool contains(Element element) {
    if (_elements.contains(element)) {
      return true;
    } else if (outerElements != null) {
      return outerElements!.contains(element);
    }
    return false;
  }

  /// Record that the given [element] has been declared, so it is no longer
  /// hidden.
  void declare(Element element) {
    _elements.remove(element);
  }

  /// Initialize the list of elements that are not yet declared to be all of the
  /// elements declared somewhere in the given [statements].
  void _initializeElements(List<Statement> statements) {
    _elements.addAll(BlockScope.elementsInStatements(statements));
  }
}

/// Information to pass from from the defining unit to augmentations.
class LibraryVerificationContext {
  final duplicationDefinitionContext = DuplicationDefinitionContext();
}

/// Recursively visits a type annotation, looking uninstantiated bounds.
class _UninstantiatedBoundChecker extends RecursiveAstVisitor<void> {
  final ErrorReporter _errorReporter;

  _UninstantiatedBoundChecker(this._errorReporter);

  @override
  void visitNamedType(NamedType node) {
    var typeArgs = node.typeArguments;
    if (typeArgs != null) {
      typeArgs.accept(this);
      return;
    }

    var element = node.element;
    if (element is TypeParameterizedElement && !element.isSimplyBounded) {
      // TODO(srawlins): Don't report this if TYPE_ALIAS_CANNOT_REFERENCE_ITSELF
      //  has been reported.
      _errorReporter.reportErrorForNode(
          CompileTimeErrorCode.NOT_INSTANTIATED_BOUND, node, []);
    }
  }
}
