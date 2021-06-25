/********************************************************************************
 * Copyright (c) 2017, 2018 Bosch Connected Devices and Solutions GmbH.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 * 
 * Contributors:
 *    Bosch Connected Devices and Solutions GmbH - initial contribution
 * 
 * SPDX-License-Identifier: EPL-2.0
 ********************************************************************************/

package org.eclipse.mita.program.generator

import com.google.inject.Inject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.nio.file.Files
import java.nio.file.Paths
import java.text.SimpleDateFormat
import java.util.Date
import java.util.function.Function
import java.util.stream.Stream
import org.eclipse.core.runtime.NullProgressMonitor
import org.eclipse.emf.ecore.EObject
import org.eclipse.emf.ecore.plugin.EcorePlugin
import org.eclipse.emf.ecore.resource.Resource
import org.eclipse.mita.base.expressions.ElementReferenceExpression
import org.eclipse.mita.base.types.AnonymousProductType
import org.eclipse.mita.base.types.Event
import org.eclipse.mita.base.types.ExceptionTypeDeclaration
import org.eclipse.mita.base.types.NamedElement
import org.eclipse.mita.base.types.NamedProductType
import org.eclipse.mita.base.types.Operation
import org.eclipse.mita.base.types.Singleton
import org.eclipse.mita.base.types.StructureType
import org.eclipse.mita.base.types.SumAlternative
import org.eclipse.mita.base.types.SystemResourceEvent
import org.eclipse.mita.base.types.TypeReferenceSpecifier
import org.eclipse.mita.base.types.TypeSpecifier
import org.eclipse.mita.base.types.TypeUtils
import org.eclipse.mita.base.typesystem.BaseConstraintFactory
import org.eclipse.mita.base.typesystem.infra.MitaBaseResource
import org.eclipse.mita.base.typesystem.types.AbstractBaseType
import org.eclipse.mita.base.typesystem.types.AbstractType
import org.eclipse.mita.base.typesystem.types.AtomicType
import org.eclipse.mita.base.typesystem.types.ProdType
import org.eclipse.mita.base.typesystem.types.SumType
import org.eclipse.mita.base.typesystem.types.TypeConstructorType
import org.eclipse.mita.base.typesystem.types.TypeHole
import org.eclipse.mita.platform.AbstractSystemResource
import org.eclipse.mita.platform.Bus
import org.eclipse.mita.platform.Connectivity
import org.eclipse.mita.platform.InputOutput
import org.eclipse.mita.platform.Modality
import org.eclipse.mita.platform.Platform
import org.eclipse.mita.platform.Sensor
import org.eclipse.mita.platform.Signal
import org.eclipse.mita.platform.SystemResourceAlias
import org.eclipse.mita.program.EventHandlerDeclaration
import org.eclipse.mita.program.FunctionDefinition
import org.eclipse.mita.program.ModalityAccess
import org.eclipse.mita.program.ModalityAccessPreparation
import org.eclipse.mita.program.NativeFunctionDefinition
import org.eclipse.mita.program.Program
import org.eclipse.mita.program.ProgramBlock
import org.eclipse.mita.program.ReturnValueExpression
import org.eclipse.mita.program.SignalInstance
import org.eclipse.mita.program.SystemEventSource
import org.eclipse.mita.program.SystemResourceSetup
import org.eclipse.mita.program.TimeIntervalEvent
import org.eclipse.mita.program.VariableDeclaration
import org.eclipse.mita.program.generator.internal.ProgramCopier
import org.eclipse.mita.program.generator.internal.UserCodeFileGenerator
import org.eclipse.mita.program.model.ModelUtils
import org.eclipse.xtext.EcoreUtil2
import org.eclipse.xtext.generator.trace.node.CompositeGeneratorNode
import org.eclipse.xtext.generator.trace.node.IGeneratorNode
import org.eclipse.xtext.generator.trace.node.NewLineNode
import org.eclipse.xtext.generator.trace.node.TextNode
import org.eclipse.xtext.scoping.IScopeProvider

import static extension org.eclipse.mita.base.util.BaseUtils.castOrNull
import static extension org.eclipse.mita.base.util.BaseUtils.force
import org.eclipse.mita.base.typesystem.types.TypeVariable
import org.eclipse.mita.base.typesystem.types.LiteralNumberType
import org.eclipse.mita.program.generator.internal.GeneratorRegistry

/**
 * Utility functions for generating code. Eventually this will be moved into the model.
 */
class GeneratorUtils {

	@Inject
	protected extension ProgramCopier

	@Inject
	protected IScopeProvider scopeProvider;
	
	@Inject
	protected GeneratorRegistry registry;

	@Inject
	protected CodeFragmentProvider codeFragmentProvider;

	@Inject(optional=true)
	protected IPlatformLoggingGenerator loggingGenerator;
	
	@Inject
	protected TypeUtils typeUtils;

	def isTopLevel(EObject obj) {
		return (EcoreUtil2.getContainerOfType(obj, Operation) as EObject ?:
			EcoreUtil2.getContainerOfType(obj, EventHandlerDeclaration)) === null
	}

	/**
	 * Opens the file at *fileLoc* either absolute or relative to the current project, depending on whether the path is absolute or relative.
	 * In the case of the standalone compiler this will open *fileLoc* relative to the user's command.
	 * If the file does not exist, returns null.
	 */
	def Stream<String> getFileContents(Resource resourceInProject, String fileLoc) {
		val path = Paths.get(fileLoc);
		return (if (path.isAbsolute) {
			if (!Files.exists(path)) {
				null;
			} else {
				Files.newBufferedReader(path);
			}
		} else {
			val workspaceRoot = EcorePlugin.workspaceRoot;
			if (workspaceRoot === null) {
				// special case for standalone compiler
				Files.newBufferedReader(path);
			} else {
				val file = workspaceRoot.getProject(resourceInProject.URI.segment(1)).getFile(fileLoc);
				if (!file.exists) {
					null;
				} else {
					file.refreshLocal(0, new NullProgressMonitor);
					new BufferedReader(new InputStreamReader(file.getContents(), file.charset));
				}
			}
		})?.lines;
	}

	def getGlobalInitName(Program program) {
		return '''initGlobalVariables_«program.eResource.URI.lastSegment.replace(MitaBaseResource.PROGRAM_EXT, "")»'''
	}

	def generateLoggingExceptionHandler(String resourceName, String action) {
		codeFragmentProvider.create('''
			if(exception == NO_EXCEPTION)
			{
				«loggingGenerator.generateLogStatement(IPlatformLoggingGenerator.LogLevel.Info, action + " " + resourceName + " succeeded")»
			}
			else
			{
				«loggingGenerator.generateLogStatement(IPlatformLoggingGenerator.LogLevel.Error, "failed to " + action + " " + resourceName)»
				return exception;
			}
		''')
	}

	def getOccurrence(EObject obj) {
		val parent = obj.eContainer;
		val EObject funDef = EcoreUtil2.getContainerOfType(parent, FunctionDefinition) as EObject ?:
			EcoreUtil2.getContainerOfType(parent, EventHandlerDeclaration) as EObject ?:
			EcoreUtil2.getContainerOfType(parent, Program) as EObject;
		val result = funDef?.eAllContents?.indexed?.findFirst[it.value.equals(obj)]?.key ?: (-1);
		return result + 1;
	}

	public def String getUniqueIdentifier(EObject obj) {
		val result = obj.uniqueIdentifierInternal.replace(".", "_") + "_" + obj.occurrence.toString;
		return result;
	}

	private def dispatch String getUniqueIdentifierInternal(Program p) {
		return p.baseName;
	}

	private def dispatch String getUniqueIdentifierInternal(EventHandlerDeclaration decl) {
		return decl.eContainer.uniqueIdentifierInternal + decl.handlerName.toFirstUpper;
	}

	private def dispatch String getUniqueIdentifierInternal(FunctionDefinition funDef) {
		return funDef.eContainer.uniqueIdentifierInternal + funDef.baseName.toFirstUpper;
	}

	private def dispatch String getUniqueIdentifierInternal(VariableDeclaration decl) {
		return decl.eContainer.uniqueIdentifierInternal + decl.baseName.toFirstUpper;
	}

	private def dispatch String getUniqueIdentifierInternal(ElementReferenceExpression expr) {
		// Erefs should only reference named things, so baseName should always be fine.
		expr.eContainer.uniqueIdentifierInternal + "Ref" + expr.reference?.baseName?.toFirstUpper;
	}

	private def dispatch String getUniqueIdentifierInternal(ProgramBlock pb) {
		pb.eContainer.uniqueIdentifierInternal + pb.eContainer.eAllContents.toList.indexOf(pb).toString;
	}

	private def dispatch String getUniqueIdentifierInternal(ReturnValueExpression rt) {
		return rt.eContainer.uniqueIdentifierInternal + "_result";
	}

	private def dispatch String getUniqueIdentifierInternal(EObject obj) {
		return obj.baseName ?: obj.eClass.name;
	}

	def dispatch String getHandlerName(EventHandlerDeclaration event) {
		val program = EcoreUtil2.getContainerOfType(event, Program);
		if (program !== null) {
			// count event handlers, so we get unique names
			val occurrence = (event.eContainer as Program).eventHandlers.filter [
				it.event.baseName == event.event.baseName
			].indexed.filter[it.value === event].head.key + 1;
			return '''HandleEvery«event.baseName»_«occurrence»''';
		}
		// if we are somehow not a child of program, default to no numbering
		return '''HandleEvery«event.baseName»''';

	}

	def dispatch String getHandlerName(EObject event) {
		val e = EcoreUtil2.getContainerOfType(event, EventHandlerDeclaration);
		if (e !== null) {
			return getHandlerName(e);
		}
		return '''HandleEvery«event.baseName»''';
	}

	def getSetupName(EObject sensor) {
		return '''«sensor.baseName»_Setup''';
	}

	def dispatch String getEnableName(AbstractSystemResource resource) {
		return '''«resource.baseName.toFirstUpper»_Enable'''
	}

	def dispatch String getEnableName(SystemResourceSetup resource) {
		return '''«resource.baseName.toFirstUpper»_Enable'''
	}

	def dispatch String getEnableName(EventHandlerDeclaration handler) {
		// TODO: handle named event handlers
		return handler.event.enableName
	}

	def dispatch getEnableName(TimeIntervalEvent event) {
		return '''Every«event.handlerName»_Enable''';
	}

	def dispatch getEnableName(Event event) {
		return '''Every«event.baseName»_Enable''';
	}

	def getReadAccessName(SignalInstance sira) {
		return '''«sira.baseName»_Read'''
	}

	def getWriteAccessName(SignalInstance siwa) {
		return '''«siwa.baseName»_Write'''
	}

	def getComponentAndSetup(EObject componentOrSetup, CompilationContext context) {
		val component = if (componentOrSetup instanceof AbstractSystemResource) {
				componentOrSetup
			} else if (componentOrSetup instanceof SystemResourceSetup) {
				componentOrSetup.type
			}
		val setup = if (componentOrSetup instanceof AbstractSystemResource) {
				context.getSetupFor(component)
			} else if (componentOrSetup instanceof SystemResourceSetup) {
				componentOrSetup
			}
		return component -> setup
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, ProdType t) {
		return '''«t.name»'''
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, SumType t) {
		return '''«t.name»'''
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, AbstractBaseType t) {
		return '''«t.name»'''
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, TypeHole t) {
		return null
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, TypeVariable t) {
		return null
	}
	
	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, LiteralNumberType t) {
		return null
	}

	private dispatch def String getFileNameForTypeImplementationInternal(EObject context, TypeConstructorType t) {
		if (t.typeArguments.size == 0) {
			return t.name
		}
		return '''«(#[t.name] + t.typeArguments.tail.map[getFileNameForTypeImplementation(context, it)]).filterNull.join("_")»'''
	}

	def String getFileNameForTypeImplementation(EObject context, AbstractType t) {
		if(t instanceof TypeConstructorType && typeUtils.isGeneratedType(context, t)) {
			var generator = registry.getGenerator(context.eResource, t)?.castOrNull(AbstractTypeGenerator);
			if(generator !== null) {
				return generator.generateHeaderName(context, t as TypeConstructorType)
			}
		}
		return getFileNameForTypeImplementationInternal(context, t)
	}
	
	def String getIncludePathForTypeImplementation(EObject context, AbstractType t) {
		return '''base/generatedTypes/«getFileNameForTypeImplementation(context, t)».h'''
	}


	def dispatch getFileBasename(AbstractSystemResource resource) {
		return '''«resource.baseName?.toFirstUpper»'''
	}

	def dispatch getFileBasename(SystemResourceSetup setup) {
		return '''«setup.baseName»'''
	}

	def dispatch getFileBasename(EObject obj) {
		return '''INVALID'''
	}

	def dispatch getResourceTypeName(Bus sensor) {
		return '''Bus''';
	}

	def dispatch getResourceTypeName(Connectivity sensor) {
		return '''Connectivity''';
	}

	def dispatch getResourceTypeName(InputOutput sensor) {
		return '''InputOutput''';
	}

	def dispatch getResourceTypeName(Platform sensor) {
		return '''Platform''';
	}

	def dispatch getResourceTypeName(Sensor sensor) {
		return '''Sensor''';
	}

	def dispatch String getResourceTypeName(SystemResourceAlias alias) {
		return alias.delegate.resourceTypeName;
	}

	def dispatch String getBaseName(Program p) {
		return p.name ?: "";
	}

	def dispatch String getBaseName(ElementReferenceExpression eref) {
		return eref.reference?.baseName;
	}

	def dispatch String getBaseName(Operation element) {
		return '''«element.name»«FOR p : element.parameters BEFORE '_' SEPARATOR '_'»«val t = p.typeSpecifier»«t.toFunctionNamePart(t.separator)»«ENDFOR»'''
	}

	def String getSeparator(TypeSpecifier t) {
		return new String(newCharArrayOfSize(doGetSeparator(t))).replace(0 as char, "_");
	}

	def dispatch int doGetSeparator(TypeSpecifier t) {
		return 0;
	}

	def dispatch int doGetSeparator(TypeReferenceSpecifier t) {
		return (#[-1] + t.typeArguments.map[doGetSeparator]).max + 1
	}

	def dispatch String toFunctionNamePart(TypeSpecifier t, String separator) {
		""
	}

	def dispatch String toFunctionNamePart(TypeReferenceSpecifier t, String separator) {
		val typeArgs = t.typeArguments.map[it.toFunctionNamePart(separator.substring(1))].filter[!nullOrEmpty].force;
		(#[t.type.name] + typeArgs).join(separator)
	}

	def dispatch String getBaseName(AbstractSystemResource resource) {
		return '''«resource.resourceTypeName»«resource.name.toFirstUpper»'''
	}

	def dispatch String getBaseName(SystemResourceSetup setup) {
		'''«setup.type.baseName»«setup.name?.toFirstUpper»'''
	}

	def dispatch String getBaseName(NamedElement element) {
		return '''«element.name»'''
	}

	def dispatch String getBaseName(ExceptionTypeDeclaration event) {
		return '''EXCEPTION_«event.name.toUpperCase»'''
	}

	def dispatch String getBaseName(EventHandlerDeclaration event) {
		return event.event.baseName;
	} 

	def dispatch String getBaseName(SystemEventSource event) {
		val origin = event.origin;
		return if (origin instanceof SystemResourceAlias) {
			val instanceName = origin.name;
			'''«instanceName.toFirstUpper»«event.source.name.toFirstUpper»'''
		} else {
			return '''«event.origin.name.toFirstLower»«IF event.signalInstance !== null»«event.signalInstance.name.toFirstUpper»«ENDIF»«event.source.name.toFirstUpper»'''
		}
	}

	def dispatch String getBaseName(SystemResourceEvent event) {
		var parent = event.eContainer;
		if (parent instanceof AbstractSystemResource) {
			return '''«parent.name.toFirstUpper»«event.name.toFirstUpper»'''
		} else if (parent instanceof Signal) {
			var systemResource = parent.eContainer as AbstractSystemResource;
			'''«systemResource.name.toFirstUpper»«parent.name.toFirstUpper»«event.name.toFirstUpper»'''
		}
	}

	def dispatch String getBaseName(TimeIntervalEvent event) {
		return '''«event.interval.value»«event.unit.literal.toFirstUpper»'''
	}

	def dispatch String getBaseName(Event event) {
		val parentName = EcoreUtil2.getID(event.eContainer).toFirstUpper;
		val eventName = event.name.toFirstUpper;
		return '''«parentName»«eventName»'''
	}

	def dispatch String getBaseName(Modality modality) {
		return '''«modality.eContainer.baseName»_«modality.name.toFirstUpper»'''
	}

	def dispatch String getBaseName(SignalInstance vci) {
		return '''«vci.eContainer.baseName»_«vci.name.toFirstUpper»'''
	}

	def dispatch String getBaseName(NativeFunctionDefinition fd) {
		return fd.name;
	}

	def dispatch String getBaseName(Object ob) {
		return null
	}

	dispatch def CodeFragment getEnumName(SumType sumType, EObject context) {
		return codeFragmentProvider.create('''«sumType.name»_enum''').addHeaderIncludes(context, sumType);
	}

	dispatch def CodeFragment getEnumName(ProdType prodType, EObject context) {
		val parentName = TypeUtils.getConstraintSystem(context.eResource).getUserData(prodType,
			BaseConstraintFactory.PARENT_NAME_KEY);
		if (parentName !== null) {
			return codeFragmentProvider.create('''«parentName»_«prodType.name»_e''').addHeaderIncludes(context,
				prodType);
		}
		return codeFragmentProvider.create('''«prodType.name»_e/*WARNING parent null*/''')
	}

	dispatch def CodeFragment getEnumName(org.eclipse.mita.base.types.SumType sumType) {
		return codeFragmentProvider.create('''«sumType.name»_enum''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(sumType)) + ".h", false);
	}

	dispatch def CodeFragment getEnumName(SumAlternative sumAlt) {
		val parentName = (sumAlt.eContainer.castOrNull(org.eclipse.mita.base.types.SumType))?.name;
		if (parentName !== null) {
			return codeFragmentProvider.create('''«parentName»_«sumAlt.name»_e''').addHeader(
				UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(sumAlt)) + ".h", false);
		}
		return codeFragmentProvider.create('''«sumAlt.name»_e/*WARNING parent null*/''')
	}

	dispatch def CodeFragment getEnumName(EObject obj) {
		return codeFragmentProvider.create('''ERROR: getEnumName''');
	}

	dispatch def CodeFragment getEnumName(AbstractType t, EObject obj) {
		return codeFragmentProvider.create('''ERROR: getEnumName''');
	}

	dispatch def CodeFragment getNameInStruct(SumType sumType, EObject context) {
		return codeFragmentProvider.create('''«sumType.name»''').addHeaderIncludes(context, sumType);
	}

	dispatch def CodeFragment getNameInStruct(SumAlternative sumAlternative) {
		return codeFragmentProvider.create('''«sumAlternative.name»''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(sumAlternative)) + ".h", false);
	}

	dispatch def CodeFragment getNameInStruct(ProdType prodType, EObject context) {
		return codeFragmentProvider.create('''«prodType.name»''').addHeaderIncludes(context, prodType);
	}

	dispatch def CodeFragment getNameInStruct(EObject obj) {
		return codeFragmentProvider.create('''ERROR: getNameInStruct''');
	}

	dispatch def CodeFragment getNameInStruct(AbstractType t, EObject obj) {
		return codeFragmentProvider.create('''ERROR: getNameInStruct''');
	}

	dispatch def CodeFragment getStructName(StructureType structureType) {
		return codeFragmentProvider.create('''«structureType.baseName»''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(structureType)) + ".h", false);
	}

	dispatch def CodeFragment getStructType(AtomicType singleton, EObject context) {
		if (TypeUtils.getConstraintSystem(context.eResource).getUserData(singleton, BaseConstraintFactory.ECLASS_KEY) ==
			"Singleton") {
			// singletons don't contain actual data
			return codeFragmentProvider.create('''void''').addHeaderIncludes(context, singleton);
		}
		// otherwise this is something like "bool" 
		return codeFragmentProvider.create('''«singleton.name»''').addHeaderIncludes(context, singleton);
	}

	dispatch def CodeFragment getStructType(ProdType productType, EObject context) {
		return codeFragmentProvider.create('''«productType.name»_t''').addHeaderIncludes(context, productType);
	}

	dispatch def CodeFragment getStructType(SumType sumType, EObject context) {
		return codeFragmentProvider.create('''«sumType.name»_t''').addHeaderIncludes(context, sumType);
	}

	dispatch def CodeFragment getStructType(TypeConstructorType type, EObject context) {
		return codeFragmentProvider.create('''«type.name»_t''').addHeaderIncludes(context, type);
	}

	def CodeFragment addHeaderIncludes(CodeFragment fragment, EObject context, AbstractType type) {
		val constraintSystem = TypeUtils.getConstraintSystem(context.eResource);
		if (constraintSystem === null) {
			return fragment;
		}
		val definingResourceName = constraintSystem.getUserData(type, BaseConstraintFactory.DEFINING_RESOURCE_KEY);
		if (definingResourceName !== null) {
			fragment.addHeader(UserCodeFileGenerator.getResourceTypesName(definingResourceName) + ".h", false);
		}
		val additionalInclude = constraintSystem.getUserData(type, BaseConstraintFactory.INCLUDE_HEADER_KEY);
		val additionalIncludeIsUserIncludeStr = constraintSystem.getUserData(type,
			BaseConstraintFactory.INCLUDE_IS_USER_INCLUDE_KEY);
		val additionalIncludeIsUserInclude = if (!additionalIncludeIsUserIncludeStr.nullOrEmpty) {
				Boolean.getBoolean(additionalIncludeIsUserIncludeStr);
			}
		if (additionalInclude !== null) {
			fragment.addHeader(additionalInclude, additionalIncludeIsUserInclude);
		}
		return fragment;
	}

	dispatch def CodeFragment getStructType(Singleton singleton) {
		// singletons don't contain actual data
		return codeFragmentProvider.create('''void''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(singleton)) + ".h", false);
	}

	dispatch def CodeFragment getStructType(AnonymousProductType productType) {
		if (productType.typeSpecifiers.length > 1) {
			return codeFragmentProvider.create('''«productType.baseName»_t''').addHeader(
				UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(productType)) + ".h",
				false);
		} else {
			// we have only one type specifier, so we shorten to an alias
			return codeFragmentProvider.create('''ERROR: ONLY ONE MEMBER, SO USE THAT ONE'S SPECIFIER''');
		}
	}

	dispatch def CodeFragment getStructType(NamedProductType productType) {
		return codeFragmentProvider.create('''«productType.baseName»_t''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(productType)) + ".h", false);
	}

	dispatch def CodeFragment getStructType(org.eclipse.mita.base.types.SumType sumType) {
		return codeFragmentProvider.create('''«sumType.baseName»_t''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(sumType)) + ".h", false);
	}

	dispatch def CodeFragment getStructType(StructureType productType) {
		return codeFragmentProvider.create('''«productType.baseName»_t''').addHeader(
			UserCodeFileGenerator.getResourceTypesName(ModelUtils.getPackageAssociation(productType)) + ".h", false);
	}

	dispatch def CodeFragment getStructType(EObject obj) {
		return codeFragmentProvider.create('''ERROR: getStructType''')
	}

	def dispatch String getBaseName(Sensor sensor) {
		return sensor.name.toFirstUpper
	}

	def dispatch String getBaseName(ModalityAccess modalityAccess) {
		return '''«modalityAccess.preparation.baseName»«modalityAccess.modality.baseName.toFirstUpper»'''
	}

	def dispatch String getBaseName(ModalityAccessPreparation modality) {
		return '''«modality.systemResource.baseName»ModalityPreparation'''
	}

	def generateHeaderComment(CompilationContext context) {
		'''
			/**
			 * Generated by Eclipse Mita «context.mitaVersion».
			 * @date «new SimpleDateFormat("yyyy-MM-dd").format(new Date())»
			 */
			
		'''
	}

	def generateExceptionHandler(EObject context, String variableName) {
		'''
			«IF variableName != 'exception'»exception = «variableName»;«ENDIF»
			if(exception != NO_EXCEPTION) «IF ModelUtils.isInTryCatchFinally(context)»break«ELSE»return «variableName»«ENDIF»;
		'''
	}

	def IGeneratorNode trim(IGeneratorNode stmt, boolean lastOccurance, Function<CharSequence, CharSequence> trimmer) {
		if (stmt instanceof TextNode) {
			stmt.text = trimmer.apply(stmt.text);
		} else if (stmt instanceof CompositeGeneratorNode) {
			val trimmableNodePrefix = [ IGeneratorNode node |
				var isNewLineNode = node instanceof NewLineNode;
				var isEmptyTextNode = if (node instanceof TextNode) {
						node.text.length == 0
					} else if (node instanceof CodeFragment) {
						node == CodeFragment.EMPTY
					} else {
						false
					}
				return !(isNewLineNode || isEmptyTextNode);
			]

			val child = if (!lastOccurance) {
					stmt.children.findFirst[trimmableNodePrefix.apply(it)]
				} else {
					stmt.children.findLast[trimmableNodePrefix.apply(it)]
				}
			child?.trim(lastOccurance, trimmer);
		}

		return stmt;
	}

	def IGeneratorNode noNewline(IGeneratorNode stmt) {
		if (stmt instanceof CompositeGeneratorNode) {
			val newChildren = stmt.children.toList.dropWhile [
				it instanceof NewLineNode || (it instanceof TextNode && (it as TextNode).text == "")
			].toList.reverse.dropWhile [
				it instanceof NewLineNode || (it instanceof TextNode && (it as TextNode).text == "")
			].toList.reverse.map[it.noNewline]

			stmt.children.clear();
			stmt.children.addAll(newChildren);
		}

		return stmt
	}

	def IGeneratorNode noTerminator(IGeneratorNode stmt) {
		trim(stmt, true, [x|x.trimTerminator]).noNewline;
	}

	def CharSequence trimTerminator(CharSequence stmt) {
		if(stmt === null) return null;

		var result = stmt.toString.trim;
		if (result.endsWith(';')) {
			result = result.substring(0, result.length - 1);
		}
		return result;
	}

	protected def trimBraces(CharSequence code) {
		var result = code.toString.trim();
		if (result.startsWith('{')) {
			result = result.substring(1);
		}
		result = result.replaceAll("\\}$", "");
		return result;
	}

	def IGeneratorNode noBraces(IGeneratorNode stmt) {
		trim(stmt, false, [x|trimBraces(x)]);
		trim(stmt, true, [x|trimBraces(x)]);
	}

	def getAllTimeEvents(CompilationContext context) {
		return context.allEventHandlers.filter[x|x.event instanceof TimeIntervalEvent]
	}

	def boolean containsCodeRelevantContent(Program it) {
		!eventHandlers.empty || !functionDefinitions.empty || !types.empty || !globalVariables.empty
	}

	def boolean needsCast(EObject obj) {
		return EcoreUtil2.getContainerOfType(obj, ProgramBlock) !== null;
	}

}
