import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/src/type_checker.dart';

import 'expression_parser/ast.dart' as ast;

final _stringTypeChecker = TypeChecker.fromRuntime(String);

/// A wrapper around [ClassElement] which exposes the functionality
/// needed for the view compiler to find types for expressions.
class AnalyzedClass {
  final ClassElement _classElement;

  /// Whether this class has mock-like behavior.
  ///
  /// The heuristic used to determine mock-like behavior is if the analyzed
  /// class or one of its ancestors, other than [Object], implements
  /// [noSuchMethod].
  final bool isMockLike;

  AnalyzedClass(
    this._classElement, {
    this.isMockLike = false,
  });
}

/// Returns the [expression] type evaluated within context of [analyzedClass].
///
/// Returns dynamic if [expression] can't be resolved.
DartType getExpressionType(ast.AST expression, AnalyzedClass analyzedClass) {
  final typeResolver = _TypeResolver(analyzedClass._classElement);
  return expression.visit(typeResolver);
}

/// Returns the element type of [dartType], assuming it implements `Iterable`.
///
/// Returns null otherwise.
DartType getIterableElementType(DartType dartType) => dartType is InterfaceType
    ? dartType.lookUpInheritedGetter('single')?.returnType
    : null;

/// Returns whether the type [expression] is [String].
bool isString(ast.AST expression, AnalyzedClass analyzedClass) {
  final type = getExpressionType(expression, analyzedClass);
  final string = analyzedClass._classElement.context.typeProvider.stringType;
  return type.isEquivalentTo(string);
}

// TODO(het): Make this work with chained expressions.
/// Returns [true] if [expression] is immutable.
bool isImmutable(ast.AST expression, AnalyzedClass analyzedClass) {
  if (expression is ast.ASTWithSource) {
    expression = (expression as ast.ASTWithSource).ast;
  }
  if (expression is ast.LiteralPrimitive ||
      expression is ast.StaticRead ||
      expression is ast.EmptyExpr) {
    return true;
  }
  if (expression is ast.IfNull) {
    return isImmutable(expression.condition, analyzedClass) &&
        isImmutable(expression.nullExp, analyzedClass);
  }
  if (expression is ast.Binary) {
    return isImmutable(expression.left, analyzedClass) &&
        isImmutable(expression.right, analyzedClass);
  }
  if (expression is ast.Interpolation) {
    return expression.expressions.every((e) => isImmutable(e, analyzedClass));
  }
  if (expression is ast.PropertyRead) {
    if (analyzedClass == null) return false;
    var receiver = expression.receiver;
    if (receiver is ast.ImplicitReceiver ||
        (receiver is ast.StaticRead && receiver.analyzedClass != null)) {
      var clazz =
          receiver is ast.StaticRead ? receiver.analyzedClass : analyzedClass;
      var field = clazz._classElement.getField(expression.name);
      if (field != null) {
        return !field.isSynthetic && (field.isFinal || field.isConst);
      }
      var method = clazz._classElement.getMethod(expression.name);
      if (method != null) {
        // methods are immutable
        return true;
      }
    }
    return false;
  }
  return false;
}

bool isStaticGetterOrMethod(String name, AnalyzedClass analyzedClass) {
  final member = analyzedClass._classElement.getGetter(name) ??
      analyzedClass._classElement.getMethod(name);
  return member != null && member.isStatic;
}

bool isStaticSetter(String name, AnalyzedClass analyzedClass) {
  final setter = analyzedClass._classElement.getSetter(name);
  return setter != null && setter.isStatic;
}

// TODO(het): preserve any source info in the new expression
/// If this interpolation can be optimized, returns the optimized expression.
/// Otherwise, returns the original expression.
///
/// An example of an interpolation that can be optimized is `{{foo}}` where
/// `foo` is a getter on the class that is known to return a [String]. This can
/// be rewritten as just `foo`.
ast.AST rewriteInterpolate(ast.AST original, AnalyzedClass analyzedClass) {
  ast.AST unwrappedExpression = original;
  if (original is ast.ASTWithSource) {
    unwrappedExpression = original.ast;
  }
  if (unwrappedExpression is! ast.Interpolation) return original;
  ast.Interpolation interpolation = unwrappedExpression;
  if (interpolation.expressions.length == 1 &&
      interpolation.strings[0].isEmpty &&
      interpolation.strings[1].isEmpty) {
    ast.AST expression = interpolation.expressions.single;
    if (expression is ast.LiteralPrimitive) {
      return ast.LiteralPrimitive(
          expression.value == null ? '' : '${expression.value}');
    }
    if (expression is ast.PropertyRead) {
      if (analyzedClass == null) return original;
      var receiver = expression.receiver;
      if (receiver is ast.ImplicitReceiver ||
          receiver is ast.StaticRead && receiver.analyzedClass != null) {
        var clazz =
            receiver is ast.StaticRead ? receiver.analyzedClass : analyzedClass;
        var field = clazz._classElement.getField(expression.name);
        if (field != null) {
          if (_stringTypeChecker.isExactlyType(field.type)) {
            return ast.IfNull(expression, ast.LiteralPrimitive(''));
          }
        }
      }
    }
  }
  return original;
}

/// Rewrites an event tearoff as a method call.
///
/// If [original] is a [ast.PropertyRead], and a method with the same name
/// exists in [analyzedClass], then convert [original] into a [ast.MethodCall].
///
/// If the underlying method has any parameters, then assume one parameter of
/// '$event'.
ast.AST rewriteTearoff(ast.AST original, AnalyzedClass analyzedClass) {
  ast.AST unwrappedExpression = original;
  if (original is ast.ASTWithSource) {
    unwrappedExpression = original.ast;
  }
  if (unwrappedExpression is! ast.PropertyRead) return original;
  ast.PropertyRead propertyRead = unwrappedExpression;
  final method =
      analyzedClass._classElement.type.lookUpInheritedMethod(propertyRead.name);
  if (method == null) return original;

  if (method.parameters.isEmpty) {
    return _simpleMethodCall(propertyRead);
  } else {
    return _complexMethodCall(propertyRead);
  }
}

ast.AST _simpleMethodCall(ast.PropertyRead propertyRead) =>
    ast.MethodCall(propertyRead.receiver, propertyRead.name, []);

final _eventArg = ast.PropertyRead(ast.ImplicitReceiver(), '\$event');

ast.AST _complexMethodCall(ast.PropertyRead propertyRead) =>
    ast.MethodCall(propertyRead.receiver, propertyRead.name, [_eventArg]);

/// Returns [true] if [expression] could be [null].
bool canBeNull(ast.AST expression) {
  if (expression is ast.ASTWithSource) {
    expression = (expression as ast.ASTWithSource).ast;
  }
  if (expression is ast.LiteralPrimitive ||
      expression is ast.EmptyExpr ||
      expression is ast.Interpolation) {
    return false;
  }
  if (expression is ast.IfNull) {
    if (!canBeNull(expression.condition)) return false;
    return canBeNull(expression.nullExp);
  }
  return true;
}

/// A visitor for evaluating the `DartType` of an `AST` expression.
///
/// Type resolution is best effort as we don't have a fully analyzed expression.
/// The following ASTs are currently resolvable:
///
/// * `MethodCall`
/// * `PropertyRead`
/// * `SafeMethodCall`
/// * `SafePropertyRead`
class _TypeResolver extends ast.AstVisitor<DartType, dynamic> {
  final DartType _dynamicType;
  final InterfaceType _implicitReceiverType;

  _TypeResolver(ClassElement classElement)
      : _dynamicType = classElement.context.typeProvider.dynamicType,
        _implicitReceiverType = classElement.type;

  @override
  DartType visitBinary(ast.Binary ast, _) => _dynamicType;

  @override
  DartType visitChain(ast.Chain ast, _) => _dynamicType;

  @override
  DartType visitConditional(ast.Conditional ast, _) => _dynamicType;

  @override
  DartType visitEmptyExpr(ast.EmptyExpr ast, _) => _dynamicType;

  @override
  DartType visitFunctionCall(ast.FunctionCall ast, _) => _dynamicType;

  @override
  DartType visitIfNull(ast.IfNull ast, _) => _dynamicType;

  @override
  DartType visitImplicitReceiver(ast.ImplicitReceiver ast, _) =>
      _implicitReceiverType;

  @override
  DartType visitInterpolation(ast.Interpolation ast, _) => _dynamicType;

  @override
  DartType visitKeyedRead(ast.KeyedRead ast, _) => _dynamicType;

  @override
  DartType visitKeyedWrite(ast.KeyedWrite ast, _) => _dynamicType;

  @override
  DartType visitLiteralArray(ast.LiteralArray ast, _) => _dynamicType;

  @override
  DartType visitLiteralMap(ast.LiteralMap ast, _) => _dynamicType;

  @override
  DartType visitLiteralPrimitive(ast.LiteralPrimitive ast, _) => _dynamicType;

  @override
  DartType visitMethodCall(ast.MethodCall ast, _) {
    DartType receiverType = ast.receiver.visit(this, _);
    return _lookupMethodReturnType(receiverType, ast.name);
  }

  @override
  DartType visitNamedExpr(ast.NamedExpr ast, _) => _dynamicType;

  @override
  DartType visitPipe(ast.BindingPipe ast, _) => _dynamicType;

  @override
  DartType visitPrefixNot(ast.PrefixNot ast, _) => _dynamicType;

  @override
  DartType visitPropertyRead(ast.PropertyRead ast, _) {
    DartType receiverType = ast.receiver.visit(this, _);
    return _lookupGetterReturnType(receiverType, ast.name);
  }

  @override
  DartType visitPropertyWrite(ast.PropertyWrite ast, _) => _dynamicType;

  @override
  DartType visitSafeMethodCall(ast.SafeMethodCall ast, _) {
    DartType receiverType = ast.receiver.visit(this, _);
    return _lookupMethodReturnType(receiverType, ast.name);
  }

  @override
  DartType visitSafePropertyRead(ast.SafePropertyRead ast, _) {
    DartType receiverType = ast.receiver.visit(this, _);
    return _lookupGetterReturnType(receiverType, ast.name);
  }

  @override
  DartType visitStaticRead(ast.StaticRead ast, _) => _dynamicType;

  /// Returns the return type of [getterName] on [receiverType], if it exists.
  ///
  /// Returns dynamic if [receiverType] has no [getterName].
  DartType _lookupGetterReturnType(DartType receiverType, String getterName) {
    if (receiverType is InterfaceType) {
      var getter = receiverType.lookUpInheritedGetter(getterName);
      if (getter != null) return getter.returnType;
    }
    return _dynamicType;
  }

  /// Returns the return type of [methodName] on [receiverType], if it exists.
  ///
  /// Returns dynamic if [receiverType] has no [methodName].
  DartType _lookupMethodReturnType(DartType receiverType, String methodName) {
    if (receiverType is InterfaceType) {
      var method = receiverType.lookUpInheritedMethod(methodName);
      if (method != null) return method.returnType;
    }
    return _dynamicType;
  }
}
